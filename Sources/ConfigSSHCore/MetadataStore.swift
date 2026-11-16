import Darwin
import Foundation
import SQLite3

package struct HostMetadata {
    package let hostKey: String
    package var displayName: String
    package var groupName: String
    package var tags: [String]
    package var isFavorite: Bool
    package var preferredTerminal: String?
    package var preferredOpenMode: String?
    package var note: String

    package init(hostKey: String, displayName: String = "", groupName: String = "",
                 tags: [String] = [], isFavorite: Bool = false,
                 preferredTerminal: String? = nil, preferredOpenMode: String? = nil, note: String = "") {
        self.hostKey = hostKey
        self.displayName = displayName
        self.groupName = groupName
        self.tags = tags
        self.isFavorite = isFavorite
        self.preferredTerminal = preferredTerminal
        self.preferredOpenMode = preferredOpenMode
        self.note = note
    }
}

package struct LaunchEvent: Identifiable {
    package let id: UUID
    package let hostKey: String
    package let terminal: String
    package let requestedAt: Date
}

package enum MetadataError: LocalizedError {
    case database(String)

    package var errorDescription: String? {
        if case .database(let message) = self { return message }
        return nil
    }
}

package final class MetadataStore {
    package let databaseURL: URL
    private let database: OpaquePointer

    package init(databaseURL: URL = ConfigSSHPaths.metadataURL) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        try SafeFileIO.ensureDirectory(databaseURL.deletingLastPathComponent())
        let descriptor = databaseURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        } else if errno != EEXIST {
            throw MetadataError.database("无法创建本地元数据文件：系统错误 \(errno)")
        }
        let values = try databaseURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw MetadataError.database("元数据路径不是普通文件")
        }

        var handle: OpaquePointer?
        let status = sqlite3_open_v2(databaseURL.path, &handle,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw MetadataError.database("无法打开本地元数据数据库")
        }
        self.database = handle
        sqlite3_busy_timeout(handle, 3_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("""
            CREATE TABLE IF NOT EXISTS host_metadata (
                host_key TEXT PRIMARY KEY,
                display_name TEXT NOT NULL DEFAULT '',
                group_name TEXT NOT NULL DEFAULT '',
                tags_json TEXT NOT NULL DEFAULT '[]',
                is_favorite INTEGER NOT NULL DEFAULT 0,
                preferred_terminal TEXT,
                preferred_open_mode TEXT,
                note TEXT NOT NULL DEFAULT ''
            )
            """)
        try ensureColumn("host_metadata", name: "preferred_open_mode", declaration: "TEXT")
        try execute("""
            CREATE TABLE IF NOT EXISTS launch_events (
                id TEXT PRIMARY KEY,
                host_key TEXT NOT NULL,
                terminal TEXT NOT NULL,
                requested_at REAL NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS launch_events_time ON launch_events(requested_at DESC)")
    }

    deinit { sqlite3_close(database) }

    package func allMetadata() throws -> [String: HostMetadata] {
        let statement = try prepare("SELECT host_key, display_name, group_name, tags_json, is_favorite, preferred_terminal, preferred_open_mode, note FROM host_metadata")
        defer { sqlite3_finalize(statement) }
        var result: [String: HostMetadata] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let key = columnText(statement, 0)
            let tagsData = Data(columnText(statement, 3).utf8)
            let tags = (try? JSONDecoder().decode([String].self, from: tagsData)) ?? []
            let terminal = TerminalProfile.canonicalID(columnText(statement, 5))
            let openMode = columnText(statement, 6)
            result[key] = HostMetadata(hostKey: key, displayName: columnText(statement, 1),
                                       groupName: columnText(statement, 2), tags: tags,
                                       isFavorite: sqlite3_column_int(statement, 4) != 0,
                                       preferredTerminal: terminal, preferredOpenMode: openMode.isEmpty ? nil : openMode,
                                       note: columnText(statement, 7))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure("读取主机元数据失败") }
        return result
    }

    package func save(_ metadata: HostMetadata) throws {
        let statement = try prepare("""
            INSERT INTO host_metadata (host_key, display_name, group_name, tags_json, is_favorite, preferred_terminal, preferred_open_mode, note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(host_key) DO UPDATE SET
                display_name=excluded.display_name, group_name=excluded.group_name,
                tags_json=excluded.tags_json, is_favorite=excluded.is_favorite,
                preferred_terminal=excluded.preferred_terminal, preferred_open_mode=excluded.preferred_open_mode,
                note=excluded.note
            """)
        defer { sqlite3_finalize(statement) }
        bind(metadata.hostKey, to: statement, at: 1)
        bind(metadata.displayName, to: statement, at: 2)
        bind(metadata.groupName, to: statement, at: 3)
        bind(String(decoding: try JSONEncoder().encode(metadata.tags), as: UTF8.self), to: statement, at: 4)
        sqlite3_bind_int(statement, 5, metadata.isFavorite ? 1 : 0)
        if let terminal = metadata.preferredTerminal {
            bind(terminal, to: statement, at: 6)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        if let mode = metadata.preferredOpenMode { bind(mode, to: statement, at: 7) }
        else { sqlite3_bind_null(statement, 7) }
        bind(metadata.note, to: statement, at: 8)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("保存主机元数据失败") }
    }

    package func moveHostKeys(_ mappings: [(from: String, to: String)]) throws {
        guard !mappings.isEmpty else { return }
        try inTransaction { try moveHostKeysWithinTransaction(mappings) }
    }

    package func clearGroup(named name: String) throws {
        try inTransaction { try clearGroupWithinTransaction(named: name) }
    }

    package func completeGroupDeletion(mappings: [(from: String, to: String)], groupName: String) throws {
        try inTransaction {
            try moveHostKeysWithinTransaction(mappings)
            try clearGroupWithinTransaction(named: groupName)
        }
    }

    private func moveHostKeysWithinTransaction(_ mappings: [(from: String, to: String)]) throws {
        for mapping in mappings {
            let present = try prepare("SELECT 1 FROM host_metadata WHERE host_key = ? LIMIT 1")
            bind(mapping.from, to: present, at: 1)
            let presentStatus = sqlite3_step(present)
            sqlite3_finalize(present)
            guard presentStatus == SQLITE_ROW || presentStatus == SQLITE_DONE else {
                throw failure("检查主机元数据失败")
            }
            if presentStatus == SQLITE_ROW {
                let conflict = try prepare("SELECT 1 FROM host_metadata WHERE host_key = ? LIMIT 1")
                bind(mapping.to, to: conflict, at: 1)
                let conflictStatus = sqlite3_step(conflict)
                sqlite3_finalize(conflict)
                guard conflictStatus == SQLITE_DONE else {
                    throw MetadataError.database("目标主机已有元数据，拒绝覆盖：\(mapping.to)")
                }
                let statement = try prepare("UPDATE host_metadata SET host_key = ? WHERE host_key = ?")
                bind(mapping.to, to: statement, at: 1)
                bind(mapping.from, to: statement, at: 2)
                let status = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard status == SQLITE_DONE else { throw failure("迁移主机元数据失败") }
            }
            let eventStatement = try prepare("UPDATE launch_events SET host_key = ? WHERE host_key = ?")
            bind(mapping.to, to: eventStatement, at: 1)
            bind(mapping.from, to: eventStatement, at: 2)
            let eventStatus = sqlite3_step(eventStatement)
            sqlite3_finalize(eventStatement)
            guard eventStatus == SQLITE_DONE else { throw failure("迁移启动历史失败") }
        }
    }

    private func clearGroupWithinTransaction(named name: String) throws {
        let statement = try prepare("UPDATE host_metadata SET group_name = '' WHERE group_name = ?")
        defer { sqlite3_finalize(statement) }
        bind(name, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("清除主机分组失败") }
    }

    private func inTransaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    package func recordLaunch(hostKey: String, terminal: String, at date: Date = Date()) throws {
        let statement = try prepare("INSERT INTO launch_events (id, host_key, terminal, requested_at) VALUES (?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(UUID().uuidString, to: statement, at: 1)
        bind(hostKey, to: statement, at: 2)
        bind(terminal, to: statement, at: 3)
        sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("记录启动历史失败") }
        try execute("DELETE FROM launch_events WHERE id NOT IN (SELECT id FROM launch_events ORDER BY requested_at DESC LIMIT 200)")
    }

    package func recentEvents(limit: Int = 30) throws -> [LaunchEvent] {
        let statement = try prepare("SELECT id, host_key, terminal, requested_at FROM launch_events ORDER BY requested_at DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(0, min(limit, 200))))
        var result: [LaunchEvent] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let id = UUID(uuidString: columnText(statement, 0)),
               let terminal = TerminalProfile.canonicalID(columnText(statement, 2)) {
                result.append(LaunchEvent(id: id, hostKey: columnText(statement, 1), terminal: terminal,
                                          requestedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure("读取启动历史失败") }
        return result
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "未知 SQLite 错误"
            sqlite3_free(message)
            throw MetadataError.database(detail)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure("数据库查询准备失败") }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: bytes)
    }

    private func failure(_ action: String) -> MetadataError {
        MetadataError.database("\(action)：\(String(cString: sqlite3_errmsg(database)))")
    }

    private func ensureColumn(_ table: String, name: String, declaration: String) throws {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var found = false
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if columnText(statement, 1) == name { found = true }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure("检查数据库结构失败") }
        if !found { try execute("ALTER TABLE \(table) ADD COLUMN \(name) \(declaration)") }
    }
}
