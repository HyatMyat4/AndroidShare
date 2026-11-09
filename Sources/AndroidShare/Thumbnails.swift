import Foundation
import AppKit
import SwiftUI
import AVFoundation
import QuickLookThumbnailing
import CryptoKit

/// Makes Finder-style previews of photos and videos on the phone.
/// Photos are copied whole (they're small). Big MP4/MOV videos are previewed from a
/// few MB of the file (see VideoProbe) so a 350 MB video doesn't need a full copy.
actor ThumbnailStore {
    static let shared = ThumbnailStore()

    private var memory: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var slots = 3
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("AndroidShare/Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static let fullVideoLimit: Int64 = 30 * 1024 * 1024
    static let fallbackVideoLimit: Int64 = 150 * 1024 * 1024

    static func eligible(_ f: RemoteFile) -> Bool {
        switch f.category {
        case .image: return f.size > 0 && f.size <= 40_000_000
        case .video: return f.size > 0
        default: return false
        }
    }

    func cached(serial: String, file f: RemoteFile) -> NSImage? {
        memory[Self.key(serial, f)]
    }

    func thumbnail(adb: ADB, serial: String, file f: RemoteFile, size: CGFloat) async -> NSImage? {
        let key = Self.key(serial, f)
        if let img = memory[key] { return img }
        if failed.contains(key) { return nil }

        let pngURL = cacheDir.appendingPathComponent(key + ".png")
        if let img = NSImage(contentsOf: pngURL) { memory[key] = img; return img }

        await acquire()
        defer { release() }
        if Task.isCancelled { return nil }
        if let img = memory[key] { return img }

        let tmp = cacheDir.appendingPathComponent(key + "." + (f.ext.isEmpty ? "bin" : f.ext))
        defer { try? FileManager.default.removeItem(at: tmp) }

        var img: NSImage?
        if f.category == .video {
            if f.size > Self.fullVideoLimit, VideoProbe.isMP4Family(f.ext) {
                let built = (try? await VideoProbe.buildSkeleton(fileSize: f.size, dest: tmp) { o, l in
                    try await adb.readRange(serial, remote: f.path, offset: o, length: l)
                }) ?? false
                if built { img = await Self.videoFrame(tmp, size: size) }
                try? FileManager.default.removeItem(at: tmp)
            }
            if img == nil, f.size <= Self.fallbackVideoLimit,
               (try? await adb.pull(serial, remote: f.path, local: tmp.path)) != nil {
                img = await Self.videoFrame(tmp, size: size)
                if img == nil { img = await Self.quickLook(tmp, size: size) }
            }
        } else if (try? await adb.pull(serial, remote: f.path, local: tmp.path)) != nil {
            img = await Self.quickLook(tmp, size: size)
        }

        guard let img else { failed.insert(key); return nil }
        if let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
           let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: pngURL)
        }
        memory[key] = img
        return img
    }

    private static func quickLook(_ url: URL, size: CGFloat) async -> NSImage? {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                               scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).nsImage
    }

    private static func videoFrame(_ url: URL, size: CGFloat) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: size * 2, height: size * 2)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .positiveInfinity
        guard let (cg, _) = try? await gen.image(at: .zero) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func key(_ serial: String, _ f: RemoteFile) -> String {
        let digest = SHA256.hash(data: Data("\(serial)|\(f.signature)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func acquire() async {
        if slots > 0 { slots -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { slots += 1 } else { waiters.removeFirst().resume() }
    }
}

/// Shows a real preview for photos/videos, falling back to the file-type icon.
struct ThumbView: View {
    let model: AppModel   // passed explicitly (safe inside Table cells)
    let file: RemoteFile
    let size: CGFloat
    var corner: CGFloat = 4
    @State private var thumb: NSImage?

    var body: some View {
        ZStack {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
                    .overlay(alignment: .bottomTrailing) {
                        if file.category == .video {
                            Image(systemName: "play.fill")
                                .font(.system(size: max(7, size * 0.18)))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 1.5)
                                .padding(max(2, size * 0.06))
                        }
                    }
            } else {
                FileIcon(file: file, size: size * 0.75)
            }
        }
        .frame(width: size, height: size)
        .task(id: file.signature) {
            guard ThumbnailStore.eligible(file), let adb = model.adb, let serial = model.selectedSerial else {
                thumb = nil; return
            }
            if let c = await ThumbnailStore.shared.cached(serial: serial, file: file) { thumb = c; return }
            thumb = nil
            let img = await ThumbnailStore.shared.thumbnail(adb: adb, serial: serial, file: file, size: 220)
            if !Task.isCancelled { thumb = img }
        }
    }
}
