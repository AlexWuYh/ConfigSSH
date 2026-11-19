import Compression
import Foundation

/// A small, strict ZIP reader and writer for host-config exports.
///
/// Writing uses deflate (or stored when that is not smaller). Reading accepts only what an
/// export or an ordinary Finder zip contains: stored or deflated entries, no encryption, no
/// ZIP64, bounded entry counts and sizes, CRC-checked. It never touches the file system, so an
/// entry name can not write anywhere by itself.
package enum ZipArchive {
    package struct Entry: Equatable, Sendable {
        package let path: String
        package let content: Data
        package init(path: String, content: Data) {
            self.path = path
            self.content = content
        }
    }

    package static let maxEntries = 2_000
    package static let maxEntrySize = 16 * 1_024 * 1_024
    package static let maxTotalSize = 64 * 1_024 * 1_024

    // MARK: Writing

    package static func write(_ entries: [Entry], date: Date = Date()) throws -> Data {
        guard entries.count <= maxEntries else { throw ConfigEditError.invalid("文件数量超过限制") }
        let (dosTime, dosDate) = dosDateTime(date)
        var output = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            guard !name.isEmpty, name.count <= 65_535, entry.content.count <= maxEntrySize else {
                throw ConfigEditError.invalid("文件名或大小超出限制：\(entry.path)")
            }
            let crc = crc32(entry.content)
            var method: UInt16 = 0
            var payload = entry.content
            if let deflated = deflate(entry.content), deflated.count < entry.content.count {
                method = 8
                payload = deflated
            }
            let offset = UInt32(output.count)
            output.append(le32(0x0403_4b50))
            output.append(le16(20)); output.append(le16(0x0800)); output.append(le16(method))
            output.append(le16(dosTime)); output.append(le16(dosDate))
            output.append(le32(crc)); output.append(le32(UInt32(payload.count))); output.append(le32(UInt32(entry.content.count)))
            output.append(le16(UInt16(name.count))); output.append(le16(0))
            output.append(name); output.append(payload)

            central.append(le32(0x0201_4b50))
            central.append(le16(0x031E)); central.append(le16(20)); central.append(le16(0x0800)); central.append(le16(method))
            central.append(le16(dosTime)); central.append(le16(dosDate))
            central.append(le32(crc)); central.append(le32(UInt32(payload.count))); central.append(le32(UInt32(entry.content.count)))
            central.append(le16(UInt16(name.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0o100_644 << 16))
            central.append(le32(offset)); central.append(name)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.append(le32(0x0605_4b50)); output.append(le16(0)); output.append(le16(0))
        output.append(le16(UInt16(entries.count))); output.append(le16(UInt16(entries.count)))
        output.append(le32(UInt32(central.count))); output.append(le32(centralOffset)); output.append(le16(0))
        return output
    }

    // MARK: Reading

    package static func isZip(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B &&
            (data[data.startIndex + 2] == 3 || data[data.startIndex + 2] == 5)
    }

    package static func read(_ data: Data) throws -> [Entry] {
        let bytes = Array(data)
        guard bytes.count >= 22, bytes.count <= 96 * 1_024 * 1_024 else { throw ConfigEditError.invalid("不是有效的 zip 文件") }
        guard let eocd = findEndOfCentralDirectory(bytes) else { throw ConfigEditError.invalid("不是有效的 zip 文件（找不到目录结尾）") }
        let count = Int(u16(bytes, eocd + 10))
        let centralSize = Int(u32(bytes, eocd + 12))
        let centralOffset = Int(u32(bytes, eocd + 16))
        guard u16(bytes, eocd + 4) == 0, u16(bytes, eocd + 6) == 0, u16(bytes, eocd + 8) == u16(bytes, eocd + 10) else {
            throw ConfigEditError.unsafe("不支持分卷 zip")
        }
        guard count != 0xFFFF, centralSize != 0xFFFF_FFFF, centralOffset != 0xFFFF_FFFF else {
            throw ConfigEditError.unsafe("不支持 ZIP64 格式")
        }
        guard count <= maxEntries else { throw ConfigEditError.unsafe("zip 内的文件数量超过限制（\(maxEntries)）") }
        guard centralOffset + centralSize <= bytes.count else { throw ConfigEditError.invalid("zip 目录已损坏") }

        var entries: [Entry] = []
        var total = 0
        var cursor = centralOffset
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, u32(bytes, cursor) == 0x0201_4b50 else { throw ConfigEditError.invalid("zip 目录已损坏") }
            let flags = u16(bytes, cursor + 8)
            let method = u16(bytes, cursor + 10)
            let crc = u32(bytes, cursor + 16)
            let compressedSize = Int(u32(bytes, cursor + 20))
            let size = Int(u32(bytes, cursor + 24))
            let nameLength = Int(u16(bytes, cursor + 28))
            let extraLength = Int(u16(bytes, cursor + 30))
            let commentLength = Int(u16(bytes, cursor + 32))
            let localOffset = Int(u32(bytes, cursor + 42))
            guard cursor + 46 + nameLength + extraLength + commentLength <= bytes.count else { throw ConfigEditError.invalid("zip 目录已损坏") }
            let nameBytes = Array(bytes[(cursor + 46)..<(cursor + 46 + nameLength)])
            cursor += 46 + nameLength + extraLength + commentLength
            guard let name = String(bytes: nameBytes, encoding: .utf8) else { throw ConfigEditError.unsafe("zip 内的文件名不是有效的 UTF-8") }
            if name.hasSuffix("/") { continue }                       // directory
            guard flags & 1 == 0 else { throw ConfigEditError.unsafe("不支持加密的 zip：\(name)") }
            guard compressedSize != 0xFFFF_FFFF, size != 0xFFFF_FFFF else { throw ConfigEditError.unsafe("不支持 ZIP64 格式") }
            guard size <= maxEntrySize else { throw ConfigEditError.unsafe("zip 内的文件超过单个大小限制：\(name)") }
            total += size
            guard total <= maxTotalSize else { throw ConfigEditError.unsafe("zip 解压后的总大小超过限制") }
            guard localOffset + 30 <= bytes.count, u32(bytes, localOffset) == 0x0403_4b50 else { throw ConfigEditError.invalid("zip 文件头已损坏：\(name)") }
            let start = localOffset + 30 + Int(u16(bytes, localOffset + 26)) + Int(u16(bytes, localOffset + 28))
            guard start + compressedSize <= bytes.count else { throw ConfigEditError.invalid("zip 数据已损坏：\(name)") }
            let payload = Data(bytes[start..<(start + compressedSize)])
            let content: Data
            switch method {
            case 0:
                guard compressedSize == size else { throw ConfigEditError.invalid("zip 数据已损坏：\(name)") }
                content = payload
            case 8:
                guard let inflated = inflate(payload, expectedSize: size) else { throw ConfigEditError.invalid("zip 数据无法解压：\(name)") }
                content = inflated
            default:
                throw ConfigEditError.unsafe("不支持的压缩方式（\(method)）：\(name)")
            }
            guard content.count == size, crc32(content) == crc else { throw ConfigEditError.invalid("zip 内文件校验失败：\(name)") }
            entries.append(Entry(path: name, content: content))
        }
        return entries
    }

    // MARK: Helpers

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        var index = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while index >= lowest {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 { return index }
            index -= 1
        }
        return nil
    }

    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 10 + 64
        var output = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { source in
            compression_encode_buffer(&output, capacity, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return written > 0 ? Data(output[0..<written]) : nil
    }

    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        if expectedSize == 0 { return data.isEmpty ? Data() : nil }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&output, expectedSize, base, data.count, nil, COMPRESSION_ZLIB)
        }
        return written == expectedSize ? Data(output) : nil
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max((parts.year ?? 1980) - 1980, 0)
        let time = UInt16(((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5) | ((parts.second ?? 0) / 2))
        let day = UInt16((year << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1))
        return (time, day)
    }

    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    private static func le32(_ value: UInt32) -> Data { Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]) }
    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
