import Darwin
import Foundation
import zlib

struct ConversationArchiveEntry: Equatable, Sendable {
    var name: String
    var data: Data
}

struct ConversationArchiveLimits: Equatable, Sendable {
    var maximumArchiveBytes = 256 * 1_024 * 1_024
    var maximumEntries = 256
    var maximumEntryBytes = 128 * 1_024 * 1_024
    var maximumExpandedBytes = 256 * 1_024 * 1_024
    var maximumCompressionRatio = 200
}

enum ConversationArchiveError: LocalizedError, Equatable, Sendable {
    case archiveTooLarge
    case invalidArchive(String)
    case unsupportedArchive(String)
    case unsafePath(String)
    case symbolicLink(String)
    case tooManyEntries
    case entryTooLarge(String)
    case expandedDataTooLarge
    case suspiciousCompressionRatio(String)
    case corruptEntry(String)
    case missingMainTranscript

    var errorDescription: String? {
        switch self {
        case .archiveTooLarge: "ZIP 文件超过安全大小上限"
        case .invalidArchive(let detail): "ZIP 结构无效：\(detail)"
        case .unsupportedArchive(let detail): "不支持的 ZIP：\(detail)"
        case .unsafePath(let path): "ZIP 包含不安全路径：\(path)"
        case .symbolicLink(let path): "ZIP 包含符号链接：\(path)"
        case .tooManyEntries: "ZIP 条目数量超过安全上限"
        case .entryTooLarge(let path): "ZIP 条目过大：\(path)"
        case .expandedDataTooLarge: "ZIP 解压后的总大小超过安全上限"
        case .suspiciousCompressionRatio(let path): "ZIP 条目压缩比异常：\(path)"
        case .corruptEntry(let path): "ZIP 条目校验失败：\(path)"
        case .missingMainTranscript: "ZIP 中没有主会话 JSONL"
        }
    }
}

enum ConversationArchive {
    struct Bundle: Equatable, Sendable {
        var main: ConversationArchiveEntry
        var subagents: [ConversationArchiveEntry]
    }

    /// Builds a deterministic, uncompressed ZIP. STORE avoids platform-specific encoders while
    /// preserving arbitrary transcript bytes exactly; the reader also accepts ordinary DEFLATE.
    static func build(
        entries: [ConversationArchiveEntry],
        limits: ConversationArchiveLimits = .init()
    ) throws -> Data {
        guard entries.count <= limits.maximumEntries else {
            throw ConversationArchiveError.tooManyEntries
        }

        var output = Data()
        var central = Data()
        var seen = Set<String>()
        var expanded = 0

        for entry in entries {
            try validate(path: entry.name)
            guard seen.insert(entry.name).inserted else {
                throw ConversationArchiveError.invalidArchive("重复条目 \(entry.name)")
            }
            guard entry.data.count <= limits.maximumEntryBytes else {
                throw ConversationArchiveError.entryTooLarge(entry.name)
            }
            guard expanded <= limits.maximumExpandedBytes - entry.data.count else {
                throw ConversationArchiveError.expandedDataTooLarge
            }
            expanded += entry.data.count

            guard let name = entry.name.data(using: .utf8),
                  name.count <= Int(UInt16.max),
                  entry.data.count <= Int(UInt32.max),
                  output.count <= Int(UInt32.max) else {
                throw ConversationArchiveError.unsupportedArchive("条目或偏移需要 ZIP64")
            }

            let checksum = crc32(entry.data)
            let localOffset = UInt32(output.count)
            output.appendLE(UInt32(0x0403_4b50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0x0800)) // UTF-8 path
            output.appendLE(UInt16(0)) // STORE
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(checksum)
            output.appendLE(UInt32(entry.data.count))
            output.appendLE(UInt32(entry.data.count))
            output.appendLE(UInt16(name.count))
            output.appendLE(UInt16(0))
            output.append(name)
            output.append(entry.data)

            central.appendLE(UInt32(0x0201_4b50))
            central.appendLE(UInt16(0x0314)) // Unix, ZIP 2.0
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(checksum)
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt32(0o100600 << 16))
            central.appendLE(localOffset)
            central.append(name)
        }

        guard output.count <= Int(UInt32.max), central.count <= Int(UInt32.max),
              output.count + central.count + 22 <= limits.maximumArchiveBytes else {
            throw ConversationArchiveError.archiveTooLarge
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.appendLE(UInt32(0x0605_4b50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt32(central.count))
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))
        return output
    }

    static func read(
        _ archive: Data,
        limits: ConversationArchiveLimits = .init()
    ) throws -> [ConversationArchiveEntry] {
        guard archive.count <= limits.maximumArchiveBytes else {
            throw ConversationArchiveError.archiveTooLarge
        }
        guard let eocd = endOfCentralDirectory(in: archive) else {
            throw ConversationArchiveError.invalidArchive("找不到中央目录")
        }
        guard archive.u16(eocd + 4) == 0, archive.u16(eocd + 6) == 0 else {
            throw ConversationArchiveError.unsupportedArchive("多磁盘归档")
        }
        let entriesOnDisk = Int(archive.u16(eocd + 8))
        let entryCount = Int(archive.u16(eocd + 10))
        let centralSize32 = archive.u32(eocd + 12)
        let centralOffset32 = archive.u32(eocd + 16)
        guard entriesOnDisk == entryCount else {
            throw ConversationArchiveError.invalidArchive("中央目录条目数不一致")
        }
        guard entryCount != Int(UInt16.max), centralSize32 != UInt32.max,
              centralOffset32 != UInt32.max else {
            throw ConversationArchiveError.unsupportedArchive("ZIP64")
        }
        guard entryCount <= limits.maximumEntries else {
            throw ConversationArchiveError.tooManyEntries
        }
        let centralOffset = Int(centralOffset32)
        let centralSize = Int(centralSize32)
        guard centralOffset >= 0, centralSize >= 0,
              centralOffset <= archive.count,
              centralSize <= archive.count - centralOffset,
              centralOffset + centralSize <= eocd else {
            throw ConversationArchiveError.invalidArchive("中央目录越界")
        }

        var entries: [ConversationArchiveEntry] = []
        entries.reserveCapacity(entryCount)
        var cursor = centralOffset
        var expanded = 0
        var seen = Set<String>()

        for _ in 0..<entryCount {
            guard archive.contains(cursor, count: 46), archive.u32(cursor) == 0x0201_4b50 else {
                throw ConversationArchiveError.invalidArchive("中央目录条目损坏")
            }
            let versionMadeBy = archive.u16(cursor + 4)
            let versionNeeded = archive.u16(cursor + 6)
            let flags = archive.u16(cursor + 8)
            let method = archive.u16(cursor + 10)
            let expectedCRC = archive.u32(cursor + 16)
            let compressed32 = archive.u32(cursor + 20)
            let uncompressed32 = archive.u32(cursor + 24)
            let nameLength = Int(archive.u16(cursor + 28))
            let extraLength = Int(archive.u16(cursor + 30))
            let commentLength = Int(archive.u16(cursor + 32))
            let diskStart = archive.u16(cursor + 34)
            let externalAttributes = archive.u32(cursor + 38)
            let localOffset32 = archive.u32(cursor + 42)
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard archive.contains(cursor, count: recordLength) else {
                throw ConversationArchiveError.invalidArchive("中央目录字段越界")
            }
            guard diskStart == 0 else {
                throw ConversationArchiveError.unsupportedArchive("跨磁盘条目")
            }
            guard versionNeeded <= 20,
                  compressed32 != UInt32.max,
                  uncompressed32 != UInt32.max,
                  localOffset32 != UInt32.max else {
                throw ConversationArchiveError.unsupportedArchive("ZIP64 或过新的 ZIP 版本")
            }
            guard flags & 0x0041 == 0 else {
                throw ConversationArchiveError.unsupportedArchive("加密条目")
            }
            let allowedFlags: UInt16 = 0x080e // UTF-8, descriptor, DEFLATE options
            guard flags & ~allowedFlags == 0 else {
                throw ConversationArchiveError.unsupportedArchive("未知条目标志")
            }
            guard method == 0 || method == 8 else {
                throw ConversationArchiveError.unsupportedArchive("压缩算法 \(method)")
            }

            let nameData = archive.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard let name = decodeName(nameData, utf8: flags & 0x0800 != 0), !name.isEmpty else {
                throw ConversationArchiveError.invalidArchive("条目名不是有效文本")
            }
            // Finder and ordinary `zip -r` archives commonly include explicit wrapping-folder
            // records. Validate the directory name without its trailing slash, fully verify its
            // empty payload below, then omit it from the in-memory file bundle.
            let isDirectory = name.hasSuffix("/")
            try validate(path: isDirectory ? String(name.dropLast()) : name)
            guard seen.insert(name).inserted else {
                throw ConversationArchiveError.invalidArchive("重复条目 \(name)")
            }
            let extraStart = cursor + 46 + nameLength
            let extra = archive.subdata(in: extraStart..<extraStart + extraLength)
            guard !containsZIP64Extra(extra) else {
                throw ConversationArchiveError.unsupportedArchive("ZIP64")
            }

            let creatorSystem = UInt8(truncatingIfNeeded: versionMadeBy >> 8)
            if creatorSystem == 3 {
                let mode = mode_t(externalAttributes >> 16)
                if mode & S_IFMT == S_IFLNK {
                    throw ConversationArchiveError.symbolicLink(name)
                }
            }

            let compressed = Int(compressed32)
            let uncompressed = Int(uncompressed32)
            guard uncompressed <= limits.maximumEntryBytes else {
                throw ConversationArchiveError.entryTooLarge(name)
            }
            guard expanded <= limits.maximumExpandedBytes - uncompressed else {
                throw ConversationArchiveError.expandedDataTooLarge
            }
            if uncompressed > 0 {
                guard compressed > 0 else {
                    throw ConversationArchiveError.suspiciousCompressionRatio(name)
                }
                let ratioLimit = compressed.multipliedReportingOverflow(
                    by: limits.maximumCompressionRatio
                )
                guard !ratioLimit.overflow, uncompressed <= ratioLimit.partialValue else {
                    throw ConversationArchiveError.suspiciousCompressionRatio(name)
                }
            }

            let localOffset = Int(localOffset32)
            guard archive.contains(localOffset, count: 30), archive.u32(localOffset) == 0x0403_4b50 else {
                throw ConversationArchiveError.corruptEntry(name)
            }
            let localFlags = archive.u16(localOffset + 6)
            let localMethod = archive.u16(localOffset + 8)
            let localNameLength = Int(archive.u16(localOffset + 26))
            let localExtraLength = Int(archive.u16(localOffset + 28))
            let localHeaderLength = 30 + localNameLength + localExtraLength
            guard localFlags == flags, localMethod == method,
                  archive.contains(localOffset, count: localHeaderLength) else {
                throw ConversationArchiveError.corruptEntry(name)
            }
            let localName = archive.subdata(
                in: localOffset + 30..<localOffset + 30 + localNameLength
            )
            guard localName == nameData else {
                throw ConversationArchiveError.corruptEntry(name)
            }
            let localExtraStart = localOffset + 30 + localNameLength
            let localExtra = archive.subdata(
                in: localExtraStart..<localExtraStart + localExtraLength
            )
            guard !containsZIP64Extra(localExtra) else {
                throw ConversationArchiveError.unsupportedArchive("ZIP64")
            }
            if flags & 0x0008 == 0 {
                guard archive.u32(localOffset + 14) == expectedCRC,
                      archive.u32(localOffset + 18) == compressed32,
                      archive.u32(localOffset + 22) == uncompressed32 else {
                    throw ConversationArchiveError.corruptEntry(name)
                }
            }
            let payloadStart = localOffset + localHeaderLength
            guard archive.contains(payloadStart, count: compressed) else {
                throw ConversationArchiveError.corruptEntry(name)
            }
            let compressedData = archive.subdata(in: payloadStart..<payloadStart + compressed)
            let value: Data
            if method == 0 {
                guard compressed == uncompressed else {
                    throw ConversationArchiveError.corruptEntry(name)
                }
                value = compressedData
            } else {
                value = try inflateRaw(compressedData, expectedSize: uncompressed, name: name)
            }
            guard value.count == uncompressed, crc32(value) == expectedCRC else {
                throw ConversationArchiveError.corruptEntry(name)
            }
            guard !isDirectory || value.isEmpty else {
                throw ConversationArchiveError.corruptEntry(name)
            }
            expanded += value.count
            if !isDirectory { entries.append(.init(name: name, data: value)) }
            cursor += recordLength
        }
        guard cursor == centralOffset + centralSize else {
            throw ConversationArchiveError.invalidArchive("中央目录大小不一致")
        }
        return entries
    }

    /// Finds the shallowest non-subagent JSONL as the main transcript. A wrapping folder is fine;
    /// subagent files are reduced to their safe basename before entering the import store.
    static func splitBundle(_ entries: [ConversationArchiveEntry]) throws -> Bundle {
        let mainCandidates = entries.filter { entry in
            let parts = pathComponents(entry.name)
            return entry.name.lowercased().hasSuffix(".jsonl")
                && !parts.contains(where: { $0.lowercased() == "subagents" })
        }.sorted {
            let lhsDepth = pathComponents($0.name).count
            let rhsDepth = pathComponents($1.name).count
            return lhsDepth == rhsDepth ? $0.name < $1.name : lhsDepth < rhsDepth
        }
        guard let main = mainCandidates.first else {
            throw ConversationArchiveError.missingMainTranscript
        }

        var subagents: [ConversationArchiveEntry] = []
        var seen = Set<String>()
        for entry in entries {
            let parts = pathComponents(entry.name)
            guard parts.dropLast().contains(where: { $0.lowercased() == "subagents" }) else {
                continue
            }
            let basename = parts.last ?? ""
            guard isSubagentBasename(basename) else { continue }
            guard seen.insert(basename.lowercased()).inserted else {
                throw ConversationArchiveError.invalidArchive("重复子代理条目 \(basename)")
            }
            subagents.append(.init(name: basename, data: entry.data))
        }
        subagents.sort { $0.name < $1.name }
        return Bundle(main: main, subagents: subagents)
    }

    static func isSubagentBasename(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !name.isEmpty && name != "." && name != ".."
            && name.utf8.count <= 255
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
            && (lower.hasSuffix(".jsonl") || lower.hasSuffix(".meta.json"))
    }

    private static func validate(path: String) throws {
        guard !path.isEmpty, !path.contains("\0"), !path.contains("\\") else {
            throw ConversationArchiveError.unsafePath(path)
        }
        guard !path.hasPrefix("/"), !path.hasPrefix("~"),
              URL(string: path)?.scheme == nil else {
            throw ConversationArchiveError.unsafePath(path)
        }
        let components = pathComponents(path)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ConversationArchiveError.unsafePath(path)
        }
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    private static func decodeName(_ data: Data, utf8: Bool) -> String? {
        if utf8 { return String(data: data, encoding: .utf8) }
        // Bundle names emitted by CC Buddy are ASCII. ISO Latin-1 is a conservative fallback for
        // legacy archives; it never introduces a slash or dot that was absent in the raw bytes.
        return String(data: data, encoding: .isoLatin1)
    }

    private static func containsZIP64Extra(_ data: Data) -> Bool {
        var offset = 0
        while offset + 4 <= data.count {
            let identifier = data.u16(offset)
            let length = Int(data.u16(offset + 2))
            guard offset + 4 + length <= data.count else { return true }
            if identifier == 0x0001 { return true }
            offset += 4 + length
        }
        return offset != data.count
    }

    private static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lower = max(0, data.count - 65_557)
        var offset = data.count - 22
        while offset >= lower {
            if data.u32(offset) == 0x0605_4b50 {
                let commentLength = Int(data.u16(offset + 20))
                if offset + 22 + commentLength == data.count { return offset }
            }
            if offset == 0 { break }
            offset -= 1
        }
        return nil
    }

    private static func inflateRaw(
        _ compressed: Data,
        expectedSize: Int,
        name: String
    ) throws -> Data {
        var output = Data(count: max(expectedSize, 1))
        var stream = z_stream()
        let initialized = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else {
            throw ConversationArchiveError.corruptEntry(name)
        }
        defer { inflateEnd(&stream) }

        let outputCapacity = output.count
        let status: Int32 = compressed.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(compressed.count)
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCapacity)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END,
              Int(stream.total_in) == compressed.count,
              Int(stream.total_out) == expectedSize else {
            throw ConversationArchiveError.corruptEntry(name)
        }
        output.count = expectedSize
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            var current = (value ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                current = current & 1 == 1
                    ? 0xedb8_8320 ^ (current >> 1)
                    : current >> 1
            }
            value = (value >> 8) ^ current
        }
        return value ^ 0xffff_ffff
    }
}

private extension Data {
    func contains(_ offset: Int, count: Int) -> Bool {
        offset >= 0 && count >= 0 && offset <= self.count && count <= self.count - offset
    }

    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[index(startIndex, offsetBy: offset)])
            | UInt16(self[index(startIndex, offsetBy: offset + 1)]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }

    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        appendLE(UInt16(truncatingIfNeeded: value))
        appendLE(UInt16(truncatingIfNeeded: value >> 16))
    }
}
