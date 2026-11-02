import Compression
import Foundation
import zlib

/// Just enough of the zip format for Bite Log's export: it writes files
/// uncompressed (photos and recordings are already compressed, and anything
/// opens such a zip) and reads both stored and deflated files, so a zip that
/// was unpacked and re-zipped on a computer still loads. No zip64, no
/// encryption: a Bite Log export is never near 4 GB.
nonisolated enum Zip {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// The most one file may unpack to, so a hostile zip can't fill the phone.
    static let maxFile = 2 << 30

    /// Writes `files` (name in the zip, file on disk) into a new zip at `out`.
    static func write(_ files: [(name: String, url: URL)], to out: URL, at date: Date = Date()) throws {
        guard files.count < 0xFFFF else { throw Failure("too many files for a zip: \(files.count)") }
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let h = try FileHandle(forWritingTo: out)
        defer { try? h.close() }
        let (time, day) = dos(date)
        var central = Data()
        var offset = 0
        for f in files {
            let data = try Data(contentsOf: f.url, options: .alwaysMapped)
            let name = Data(f.name.utf8)
            guard data.count < 0xFFFF_FFFF, offset < 0xFFFF_FFFF else { throw Failure("the export is too big for a zip") }
            let crc = checksum(data)
            var local = Data()
            local.le32(0x0403_4b50)
            local.le16(20); local.le16(0x0800); local.le16(0)  // version, UTF-8 names, stored
            local.le16(time); local.le16(day)
            local.le32(crc); local.le32(UInt32(data.count)); local.le32(UInt32(data.count))
            local.le16(UInt16(name.count)); local.le16(0)
            local.append(name)
            try h.write(contentsOf: local)
            try h.write(contentsOf: data)

            central.le32(0x0201_4b50)
            central.le16(20); central.le16(20); central.le16(0x0800); central.le16(0)
            central.le16(time); central.le16(day)
            central.le32(crc); central.le32(UInt32(data.count)); central.le32(UInt32(data.count))
            central.le16(UInt16(name.count)); central.le16(0); central.le16(0)  // name, extra, comment
            central.le16(0); central.le16(0); central.le32(0)  // disk, internal, external attributes
            central.le32(UInt32(offset))
            central.append(name)
            offset += local.count + data.count
        }
        guard offset < 0xFFFF_FFFF else { throw Failure("the export is too big for a zip") }
        var end = Data()
        end.le32(0x0605_4b50)
        end.le16(0); end.le16(0)
        end.le16(UInt16(files.count)); end.le16(UInt16(files.count))
        end.le32(UInt32(central.count)); end.le32(UInt32(offset))
        end.le16(0)
        try h.write(contentsOf: central)
        try h.write(contentsOf: end)
    }

    /// Unpacks the files `accept` takes (by their name in the zip) into `dir`,
    /// under the same names; returns those names. Folder entries are skipped;
    /// every other name must be accepted or be one `skip` allows, else it
    /// throws, as it does for a damaged file.
    static func read(_ zip: URL, into dir: URL, accept: (String) -> Bool,
                     skip: (String) -> Bool = { _ in false }) throws -> [String] {
        let d = try Data(contentsOf: zip, options: .alwaysMapped)
        func u16(_ at: Int) throws -> Int {
            guard at >= 0, at + 2 <= d.count else { throw Failure("This file is damaged or isn't a zip.") }
            return Int(d[at]) | Int(d[at + 1]) << 8
        }
        func u32(_ at: Int) throws -> Int { try u16(at) | (try u16(at + 2)) << 16 }

        // the end record: the last 22 bytes, unless the zip has a comment
        var end = -1
        var at = d.count - 22
        while at >= max(0, d.count - 22 - 0xFFFF) {
            if try u32(at) == 0x0605_4b50 { end = at; break }
            at -= 1
        }
        guard end >= 0 else { throw Failure("This file isn't a zip.") }
        let count = try u16(end + 10)
        var p = try u32(end + 16)
        guard p != 0xFFFF_FFFF else { throw Failure("This zip is in a format Bite Log can't read (zip64).") }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        for _ in 0..<count {
            guard try u32(p) == 0x0201_4b50 else { throw Failure("This file is damaged or isn't a zip.") }
            let flags = try u16(p + 8), method = try u16(p + 10)
            let crc = UInt32(try u32(p + 16)), packed = try u32(p + 20), size = try u32(p + 24)
            let nameLen = try u16(p + 28), extraLen = try u16(p + 30), commentLen = try u16(p + 32)
            let local = try u32(p + 42)
            guard p + 46 + nameLen <= d.count,
                  let name = String(data: d.subdata(in: p + 46 ..< p + 46 + nameLen), encoding: .utf8) else {
                throw Failure("This file is damaged or isn't a zip.")
            }
            p += 46 + nameLen + extraLen + commentLen
            if name.hasSuffix("/") { continue }
            guard accept(name) else {
                if skip(name) { continue }
                throw Failure("This zip has a file Bite Log doesn't expect: \(name)")
            }
            guard !names.contains(name) else { throw Failure("This zip has \(name) twice.") }
            guard flags & 1 == 0 else { throw Failure("This zip is encrypted.") }
            guard size <= maxFile else { throw Failure("\(name) is too big.") }

            guard try u32(local) == 0x0403_4b50 else { throw Failure("This file is damaged or isn't a zip.") }
            let start = local + 30 + (try u16(local + 26)) + (try u16(local + 28))
            guard start + packed <= d.count else { throw Failure("This file is damaged or cut short.") }
            let src = d.subdata(in: start ..< start + packed)
            let data: Data
            switch method {
            case 0: data = src
            case 8: data = try inflate(src, size: size, name: name)
            default: throw Failure("\(name) is compressed in a way Bite Log can't read.")
            }
            guard data.count == size, checksum(data) == crc else { throw Failure("\(name) is damaged.") }
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            names.append(name)
        }
        return names
    }

    private static func inflate(_ src: Data, size: Int, name: String) throws -> Data {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw Failure("\(name) is damaged.") }
        return out
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { b in
            UInt32(crc32(0, b.bindMemory(to: Bytef.self).baseAddress, uInt(b.count)))
        }
    }

    /// MS-DOS time and date, which zip stores, in local time.
    private static func dos(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = (c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2
        let day = max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1)
        return (UInt16(time), UInt16(day))
    }
}

nonisolated private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}
