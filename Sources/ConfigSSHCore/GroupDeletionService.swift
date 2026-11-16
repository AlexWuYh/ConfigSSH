import Darwin
import Foundation

package struct PendingGroupDeletion: Codable, Identifiable {
    package struct FileChange: Codable {
        package let path: String
        package let before: Data?
        package let after: Data?
        package let originalMode: Int?
        package let desiredMode: Int?
    }

    package struct HostKeyMove: Codable {
        package let from: String
        package let to: String
    }

    package let id: UUID
    package let name: String
    package let directoryPath: String?
    package let changes: [FileChange]
    package let keyMoves: [HostKeyMove]
}

package struct GroupDeletionService {
    package let writer: ConfigWriter
    package let metadataStore: MetadataStore
    private let journal: GroupDeletionJournalStore

    package init(writer: ConfigWriter, metadataStore: MetadataStore) {
        self.writer = writer
        self.metadataStore = metadataStore
        self.journal = GroupDeletionJournalStore(directoryURL: writer.backups.directoryURL
            .appendingPathComponent("GroupOperations"))
    }

    package func pendingOperations() throws -> [PendingGroupDeletion] {
        try journal.list()
    }

    @discardableResult
    package func prepare(_ plan: GroupDeletionPlan) throws -> PendingGroupDeletion {
        guard try pendingOperations().isEmpty else {
            throw ConfigEditError.conflict("存在未完成的分组操作，请先在主窗口继续处理")
        }
        let moves = plan.movedHosts.map { host in
            PendingGroupDeletion.HostKeyMove(
                from: host.metadataKey,
                to: "\(writer.managedDirectoryURL.appendingPathComponent(host.sourceURL.lastPathComponent).path)\u{1F}\(host.alias.lowercased())"
            )
        }
        let operation = PendingGroupDeletion(
            id: UUID(), name: plan.name, directoryPath: plan.directoryURL?.path,
            changes: plan.changePlan?.changes.map { change in
                PendingGroupDeletion.FileChange(path: change.url.path, before: change.before,
                                                after: change.after,
                                                originalMode: change.expectedVersion.mode,
                                                desiredMode: change.desiredMode)
            } ?? [],
            keyMoves: moves
        )
        try journal.save(operation)
        return operation
    }

    package func delete(_ plan: GroupDeletionPlan,
                        afterFilesCommitted: (() throws -> Void)? = nil) throws {
        let operation = try prepare(plan)
        do {
            if let changes = plan.changePlan { _ = try writer.commit(changes) }
            try afterFilesCommitted?()
            try removeDirectoryIfPresent(operation)
            try metadataStore.completeGroupDeletion(
                mappings: operation.keyMoves.map { ($0.from, $0.to) }, groupName: operation.name
            )
        } catch {
            let originalError = error
            do {
                try rollbackFiles(operation)
                try journal.remove(operation)
            } catch {
                throw ConfigEditError.io("分组操作未完成，自动恢复失败：\(error.localizedDescription)。请在主窗口继续处理；操作记录位于 \(journal.url(for: operation).path)")
            }
            throw originalError
        }
        try journal.remove(operation)
    }

    package func resume(_ operation: PendingGroupDeletion) throws {
        guard let operation = try journal.list().first(where: { $0.id == operation.id }) else {
            throw ConfigEditError.invalid("分组操作记录已不存在，请重新载入")
        }
        try validate(operation)
        let missing = try pendingFileChanges(operation, destination: .after)
        if !missing.isEmpty {
            _ = try writer.commit(ConfigChangePlan(title: "继续删除分组 \(operation.name)",
                                                   targetAlias: nil,
                                                   checkedVersions: missing.map(\.expectedVersion),
                                                   changes: missing))
        }
        for change in operation.changes {
            let current = try SafeFileIO.snapshot(at: URL(fileURLWithPath: change.path))
            guard current.data == change.after else {
                throw ConfigEditError.conflict("分组文件在继续操作时又发生变化：\(change.path)")
            }
        }
        try removeDirectoryIfPresent(operation)
        try metadataStore.completeGroupDeletion(
            mappings: operation.keyMoves.map { ($0.from, $0.to) }, groupName: operation.name
        )
        try journal.remove(operation)
    }

    private enum Destination { case before, after }

    private func validate(_ operation: PendingGroupDeletion) throws {
        if let directoryPath = operation.directoryPath {
            guard directoryPath == writer.managedDirectoryURL.appendingPathComponent(operation.name).path,
                  operation.name != ".", operation.name != "..", !operation.name.contains("/") else {
                throw ConfigEditError.unsafe("分组操作记录中的目录不在受管范围内")
            }
        }
        for change in operation.changes {
            let path = URL(fileURLWithPath: change.path).standardizedFileURL.path
            guard path == writer.rootURL.path ||
                    (path.hasPrefix(writer.managedDirectoryURL.path + "/") && path.hasSuffix(".conf")) else {
                throw ConfigEditError.unsafe("分组操作记录中的文件不在受管范围内：\(path)")
            }
        }
    }

    private func pendingFileChanges(_ operation: PendingGroupDeletion,
                                    destination: Destination) throws -> [PlannedFileChange] {
        let changes = destination == .after ? operation.changes : operation.changes.reversed()
        return try changes.compactMap { change in
            let url = URL(fileURLWithPath: change.path)
            let current = try SafeFileIO.snapshot(at: url)
            let desired = destination == .after ? change.after : change.before
            if current.data == desired { return nil }
            let expected = destination == .after ? change.before : change.after
            guard current.data == expected else {
                throw ConfigEditError.conflict("分组操作后文件又被修改，不能自动处理：\(change.path)")
            }
            return PlannedFileChange(url: url, before: current.data, after: desired,
                                     expectedVersion: current.version,
                                     desiredMode: destination == .after ? change.desiredMode : change.originalMode)
        }
    }

    private func rollbackFiles(_ operation: PendingGroupDeletion) throws {
        if let directoryPath = operation.directoryPath {
            try SafeFileIO.ensureDirectory(URL(fileURLWithPath: directoryPath))
        }
        let changes = try pendingFileChanges(operation, destination: .before)
        guard !changes.isEmpty else { return }
        _ = try writer.commit(ConfigChangePlan(title: "撤回删除分组 \(operation.name)",
                                               targetAlias: nil,
                                               checkedVersions: changes.map(\.expectedVersion),
                                               changes: changes))
    }

    private func removeDirectoryIfPresent(_ operation: PendingGroupDeletion) throws {
        guard let directoryPath = operation.directoryPath else { return }
        let directory = URL(fileURLWithPath: directoryPath)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try writer.removeEmptyGroupDirectory(GroupDeletionPlan(
            name: operation.name, directoryURL: directory, movedHosts: [], changePlan: nil
        ))
    }
}

private struct GroupDeletionJournalStore {
    let directoryURL: URL

    func url(for operation: PendingGroupDeletion) -> URL {
        directoryURL.appendingPathComponent("\(operation.id.uuidString).json")
    }

    func list() throws -> [PendingGroupDeletion] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        try SafeFileIO.ensureDirectory(directoryURL)
        let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }.map { url in
            let snapshot = try SafeFileIO.snapshot(at: url)
            guard let data = snapshot.data else {
                throw ConfigEditError.io("无法读取分组操作记录：\(url.path)")
            }
            return try JSONDecoder().decode(PendingGroupDeletion.self, from: data)
        }.sorted { $0.name < $1.name }
    }

    func save(_ operation: PendingGroupDeletion) throws {
        try SafeFileIO.ensureDirectory(directoryURL)
        let url = url(for: operation)
        let data = try JSONEncoder().encode(operation)
        let descriptor = url.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else {
            throw ConfigEditError.io("无法建立分组操作记录：\(url.path)")
        }
        var closed = false
        var complete = false
        defer {
            if !closed { _ = Darwin.close(descriptor) }
            if !complete { _ = url.path.withCString { unlink($0) } }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw ConfigEditError.io("写入分组操作记录失败") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw ConfigEditError.io("同步分组操作记录失败") }
        guard Darwin.close(descriptor) == 0 else {
            closed = true
            throw ConfigEditError.io("关闭分组操作记录失败")
        }
        closed = true
        try syncDirectory()
        complete = true
    }

    func remove(_ operation: PendingGroupDeletion) throws {
        try FileManager.default.removeItem(at: url(for: operation))
        try syncDirectory()
    }

    private func syncDirectory() throws {
        let descriptor = directoryURL.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY) }
        guard descriptor >= 0 else { throw ConfigEditError.io("无法同步分组操作目录") }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw ConfigEditError.io("无法同步分组操作目录") }
    }
}
