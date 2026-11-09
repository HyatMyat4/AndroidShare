import Foundation

/// Builds a "skeleton" copy of an MP4/MOV video using only a few small reads:
/// the header, the `moov` index (wherever it is — often at the very end), and the
/// beginning of the media data. Everything else is left as a sparse hole, so a
/// 350 MB video needs only ~5–10 MB transferred to generate a preview frame.
enum VideoProbe {
    typealias Reader = (_ offset: Int64, _ length: Int64) async throws -> Data

    static let headBytes: Int64 = 512 * 1024
    static let mediaBytes: Int64 = 4 * 1024 * 1024
    static let maxMoov: Int64 = 40 * 1024 * 1024

    static func isMP4Family(_ ext: String) -> Bool {
        ["mp4", "m4v", "mov", "3gp", "3g2"].contains(ext)
    }

    /// Returns true if a skeleton file was written to `dest`.
    static func buildSkeleton(fileSize: Int64, dest: URL, read: Reader) async throws -> Bool {
        let head = try await read(0, min(headBytes, fileSize))
        var chunks: [(Int64, Data)] = [(0, head)]
        var moovFound = false
        var mdatStart: Int64?
        var off: Int64 = 0
        var steps = 0

        func header(at o: Int64) async throws -> Data {
            if o + 16 <= Int64(head.count) { return head.subdata(in: Int(o)..<Int(o + 16)) }
            return try await read(o, min(16, fileSize - o))
        }

        while off + 8 <= fileSize, steps < 64 {
            steps += 1
            let h = try await header(at: off)
            guard h.count >= 8 else { break }
            var size = Int64(h.be32(0))
            let type = String(decoding: h.subdata(in: 4..<8), as: UTF8.self)
            var headerLen: Int64 = 8
            if size == 1 {
                guard h.count >= 16 else { break }
                size = Int64(h.be64(8)); headerLen = 16
            } else if size == 0 {
                size = fileSize - off
            }
            guard size >= headerLen else { break }

            if type == "moov" {
                guard size <= maxMoov else { return false }
                if off + size > Int64(head.count) {
                    chunks.append((off, try await read(off, size)))
                }
                moovFound = true
            } else if type == "mdat", mdatStart == nil {
                mdatStart = off + headerLen
            }
            off += size
        }

        guard moovFound else { return false }
        if let m = mdatStart {
            let start = max(m, Int64(head.count))
            let len = min(m + mediaBytes, fileSize) - start
            if len > 0 { chunks.append((start, try await read(start, len))) }
        }

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let fh = try FileHandle(forWritingTo: dest)
        defer { try? fh.close() }
        try fh.truncate(atOffset: UInt64(fileSize))   // sparse on APFS: takes no real space
        for (o, d) in chunks {
            try fh.seek(toOffset: UInt64(o))
            try fh.write(contentsOf: d)
        }
        return true
    }
}

private extension Data {
    func be32(_ i: Int) -> UInt32 {
        let b = [UInt8](self[startIndex + i ..< startIndex + i + 4])
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }
    func be64(_ i: Int) -> UInt64 {
        let b = [UInt8](self[startIndex + i ..< startIndex + i + 8])
        return b.reduce(0) { $0 << 8 | UInt64($1) }
    }
}
