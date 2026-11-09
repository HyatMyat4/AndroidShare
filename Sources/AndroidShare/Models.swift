import Foundation
import UniformTypeIdentifiers

struct Device: Identifiable, Hashable {
    let serial: String
    let state: String   // "device", "unauthorized", "offline", ...
    let model: String
    var id: String { serial }
}

struct StorageInfo: Equatable {
    let total: Int64
    let used: Int64
    var free: Int64 { max(0, total - used) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct Location: Identifiable, Hashable {
    let title: String
    let path: String
    let symbol: String
    var id: String { path }
}

enum ConnectionState: Equatable {
    case starting, noADB, noDevice, unauthorized, offline, ready
}

enum ViewMode: String, CaseIterable {
    case list, grid
}

struct RemoteFile: Identifiable, Hashable {
    let path: String
    let name: String
    let isDir: Bool
    let size: Int64
    let modified: Date
    let kind: String
    let category: Category

    var id: String { path }
    var ext: String { (name as NSString).pathExtension.lowercased() }
    var isHidden: Bool { name.hasPrefix(".") }

    enum Category { case folder, image, video, audio, document, archive, apk, other }

    init(path: String, name: String, isDir: Bool, size: Int64, modified: Date) {
        self.path = path
        self.name = name
        self.isDir = isDir
        self.size = size
        self.modified = modified
        let ext = (name as NSString).pathExtension.lowercased()
        if isDir {
            kind = "Folder"
            category = .folder
        } else {
            let type = UTType(filenameExtension: ext)
            if ext == "apk" {
                kind = "Android App"; category = .apk
            } else if let t = type {
                kind = t.localizedDescription ?? ext.uppercased()
                if t.conforms(to: .image) { category = .image }
                else if t.conforms(to: .movie) || t.conforms(to: .video) || ["webm", "mkv", "3gp"].contains(ext) { category = .video }
                else if t.conforms(to: .audio) || ["opus", "ogg", "m4a"].contains(ext) { category = .audio }
                else if t.conforms(to: .archive) { category = .archive }
                else if t.conforms(to: .text) || t.conforms(to: .pdf) || t.conforms(to: .presentation) || t.conforms(to: .spreadsheet) { category = .document }
                else { category = .other }
            } else {
                kind = ext.isEmpty ? "Document" : "\(ext.uppercased()) file"
                category = ["webm", "mkv", "3gp"].contains(ext) ? .video : .other
            }
        }
    }

    var symbol: String {
        switch category {
        case .folder: return "folder.fill"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .document: return "doc.text"
        case .archive: return "doc.zipper"
        case .apk: return "shippingbox"
        case .other: return "doc"
        }
    }

    /// Used for detecting changes on the phone.
    var signature: String { "\(path)|\(isDir)|\(size)|\(modified.timeIntervalSince1970)" }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
