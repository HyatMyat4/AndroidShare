import Foundation
import AppKit
import Network
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import QuickLookThumbnailing

/// Wi-Fi Transfer: runs the built-in web server, tracks the Mac's address,
/// and turns server events into Transfers the rest of the app already shows.
@MainActor
final class WirelessHub: ObservableObject {
    enum Status: Equatable { case off, starting, ready, noNetwork, failed(String) }

    struct OutboxItem: Identifiable, Equatable {
        let id: String
        let url: URL
        var name: String { url.lastPathComponent }
        let size: Int64
        var thumb: Data?
    }

    private static let d = UserDefaults.standard
    static let defaultPort: UInt16 = 8765

    @Published var enabled = d.bool(forKey: "wifiEnabled") {
        didSet {
            guard oldValue != enabled else { return }
            Self.d.set(enabled, forKey: "wifiEnabled")
            enabled ? start() : stop()
        }
    }
    @Published private(set) var status: Status = .off

    /// Show this Mac in Android's built-in Quick Share (Google/Samsung phones).
    @Published var quickShareEnabled = d.bool(forKey: "quickShareEnabled") {
        didSet {
            guard oldValue != quickShareEnabled else { return }
            Self.d.set(quickShareEnabled, forKey: "quickShareEnabled")
            quickShareEnabled ? startQuickShare() : stopQuickShare()
        }
    }
    @Published private(set) var quickShareStatus: Status = .off
    /// Accept Quick Share transfers without asking.
    @Published var quickShareAutoAccept = d.bool(forKey: "quickShareAutoAccept") {
        didSet { Self.d.set(quickShareAutoAccept, forKey: "quickShareAutoAccept") }
    }
    @Published private(set) var address: String?
    @Published private(set) var port: UInt16?
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var outbox: [OutboxItem] = []
    @Published private(set) var lastPhoneSeen: Date?

    private(set) var key: String
    let macName: String

    private var server: WiFiServer?
    private var quickShare: QuickShareServer?
    private weak var model: AppModel?
    private var live: [UUID: Live] = [:]
    private var receivedBatch: [URL] = []
    private var shownBigFileTip = false
    private var batchTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var preferredInterfaces: [String] = []
    private var bag = Set<AnyCancellable>()
    private lazy var icons: (Data, Data) = (Self.iconPNG(192), Self.iconPNG(512))

    private struct Live {
        let transfer: Transfer
        let dir: WiFiServer.Direction
        var lastBytes: Int64 = 0
        var lastTime = Date()
    }

    init() {
        if let k = Self.d.string(forKey: "wifiKey"), k.count >= 20 {
            key = k
        } else {
            key = Self.newKey()
            Self.d.set(key, forKey: "wifiKey")
        }
        macName = Host.current().localizedName ?? "Mac"
    }

    // MARK: Public

    /// Phone page address without the pairing key (for display).
    var pageAddress: String? {
        guard status == .ready, let a = address, let p = port else { return nil }
        return "http://\(a):\(p)"
    }

    /// What the QR code contains. The key travels in the #fragment, so it's never logged in a URL path.
    var pairingURL: String? { pageAddress.map { "\($0)/#k=\(key)" } }

    var activeCount: Int { live.count }

    func attach(_ m: AppModel) {
        guard model == nil else { return }
        model = m
        m.$downloadFolderPath
            .sink { [weak self] _ in DispatchQueue.main.async { self?.pushConfig() } }
            .store(in: &bag)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let names = path.availableInterfaces
                .filter { $0.type == .wifi || $0.type == .wiredEthernet }
                .map(\.name)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.preferredInterfaces = names
                    self?.refreshAddress()
                }
            }
        }
        pathMonitor.start(queue: .main)
        if enabled { start() }
        if quickShareEnabled { startQuickShare() }
    }

    func addToOutbox(_ urls: [URL]) {
        var skipped = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                skipped += 1; continue
            }
            if outbox.contains(where: { $0.url == url }) { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let item = OutboxItem(id: String(UUID().uuidString.prefix(8)).lowercased(), url: url, size: size)
            outbox.append(item)
            Task { [weak self] in
                guard let jpeg = await Self.thumbnailJPEG(url) else { return }
                guard let self, let i = self.outbox.firstIndex(where: { $0.id == item.id }) else { return }
                self.outbox[i].thumb = jpeg
                self.pushConfig()
            }
        }
        pushConfig()
        if skipped > 0 {
            model?.showToast("Folders can't be sent. Choose the files inside instead.", error: true)
        }
    }

    func removeFromOutbox(_ item: OutboxItem) {
        outbox.removeAll { $0.id == item.id }
        pushConfig()
    }

    func clearOutbox() {
        outbox.removeAll()
        pushConfig()
    }

    /// Makes a new pairing key. Every phone has to scan the QR code again.
    func resetPairing() {
        key = Self.newKey()
        Self.d.set(key, forKey: "wifiKey")
        pushConfig()
        updateQR()
        objectWillChange.send()
        model?.showToast("All phones unpaired. Scan the new QR code to pair again.")
    }

    // MARK: Server lifecycle

    private func start() {
        guard model != nil else { return }   // attach() will start us
        server?.stop()
        status = .starting
        let s = WiFiServer()
        s.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        server = s
        pushConfig()
        let saved = Self.d.integer(forKey: "wifiPort")
        s.start(preferredPort: saved > 1024 && saved < 65000 ? UInt16(saved) : Self.defaultPort)
    }

    private func stop() {
        server?.stop()
        server = nil
        status = .off
        port = nil
        qrImage = nil
        // Open connections report themselves as cancelled once the server shuts them down.
    }

    // MARK: Quick Share

    private func startQuickShare() {
        guard model != nil else { return }
        quickShare?.stop()
        quickShareStatus = .starting
        let q = QuickShareServer()
        q.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleQuickShare(event) }
            }
        }
        quickShare = q
        pushConfig()
        q.start()
    }

    private func stopQuickShare() {
        quickShare?.stop()
        quickShare = nil
        quickShareStatus = .off
    }

    private func handleQuickShare(_ e: QuickShareServer.Event) {
        guard quickShare != nil, let model else { return }
        switch e {
        case .ready:
            quickShareStatus = .ready
        case .failed(let m):
            quickShareStatus = .failed(m)
        case .transfer(let t):
            handle(t)
        case .request(let r):
            if quickShareAutoAccept { r.respond(true); return }
            askToAccept(r)
        case let .text(text, isURL, from):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if isURL, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true {
                NSWorkspace.shared.open(url)
                model.showToast("Opened link from \(from) (also copied)")
            } else {
                model.showToast("Text from \(from) copied to clipboard")
            }
        }
    }

    private func askToAccept(_ r: QuickShareServer.Request) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let total = r.files.reduce(Int64(0)) { $0 + $1.size }
        let what: String
        if r.files.isEmpty {
            what = r.textTitles.count == 1 ? "some text" : "\(r.textTitles.count) texts"
        } else if r.files.count == 1 {
            what = "“\(r.files[0].name)”"
        } else {
            what = "\(r.files.count) files"
        }
        alert.messageText = "\(r.device) wants to send you \(what)"
        var lines = r.files.prefix(6).map { "• \($0.name)  (\($0.size.byteString))" }
        if r.files.count > 6 { lines.append("• …and \(r.files.count - 6) more") }
        if !r.files.isEmpty { lines.append("\nTotal: \(total.byteString). Saved to \(model?.downloadFolder.lastPathComponent ?? "Downloads").") }
        lines.append("\nPIN: \(r.pin). Check that it matches the one on the phone.")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Accept")
        alert.addButton(withTitle: "Decline")
        r.respond(alert.runModal() == .alertFirstButtonReturn)
    }

    private func pushConfig() {
        if let quickShare, let model {
            quickShare.config = .init(deviceName: macName, saveFolder: model.downloadFolder)
        }
        guard let server, let model else { return }
        var c = WiFiServer.Config()
        c.key = key
        c.saveFolder = model.downloadFolder
        c.macName = macName
        c.outbox = outbox.map { WiFiServer.OutboxEntry(id: $0.id, url: $0.url, name: $0.name, thumb: $0.thumb) }
        c.icon192 = icons.0
        c.icon512 = icons.1
        server.config = c
    }

    private func refreshAddress() {
        address = Self.localIPv4(preferring: preferredInterfaces)
        guard server != nil, port != nil else { return }
        status = address == nil ? .noNetwork : .ready
        updateQR()
    }

    private func updateQR() {
        qrImage = pairingURL.flatMap(Self.makeQR)
    }

    // MARK: Events

    private func handle(_ e: WiFiServer.Event) {
        guard let model else { return }
        switch e {
        case .listening(let p):
            guard server != nil else { return }
            port = p
            Self.d.set(Int(p), forKey: "wifiPort")
            status = .starting
            refreshAddress()

        case .failed(let msg):
            guard server != nil else { return }
            status = .failed(msg)

        case .phoneSeen:
            if lastPhoneSeen.map({ Date().timeIntervalSince($0) > 5 }) ?? true { lastPhoneSeen = Date() }

        case let .started(id, dir, name, size, cancel):
            let t = Transfer(kind: dir == .receive ? .wifiReceive : .wifiSend,
                             name: name,
                             detail: dir == .receive ? "from phone" : "to phone",
                             total: { size }, probe: { 0 }, work: { _ in })
            t.totalBytes = size
            t.box.onCancel(cancel)
            if dir == .receive, size >= 1_000_000_000, !shownBigFileTip {
                shownBigFileTip = true
                model.showToast("Big file (\(size.byteString)). Next time, a USB cable is usually 3–10× faster.")
            }
            model.transfers.track(t)
            live[id] = Live(transfer: t, dir: dir)

        case let .progress(id, bytes):
            guard var l = live[id] else { return }
            let now = Date()
            let dt = now.timeIntervalSince(l.lastTime)
            if dt >= 0.4 {
                let inst = Double(bytes - l.lastBytes) / dt
                l.transfer.speed = l.transfer.speed == 0 ? inst : l.transfer.speed * 0.6 + inst * 0.4
                l.lastBytes = bytes
                l.lastTime = now
            }
            l.transfer.bytesDone = bytes
            live[id] = l

        case let .finished(id, dir, outcome):
            guard let l = live.removeValue(forKey: id) else { return }
            let t = l.transfer
            switch outcome {
            case .done(let url):
                t.bytesDone = t.totalBytes
                t.resultURL = url
                t.state = .done
                if dir == .receive, let url { receivedBatch.append(url) }
            case .failed(let msg):
                t.state = .failed(msg)
            case .cancelled:
                t.state = .cancelled
            }
            model.transfers.objectWillChange.send()
            scheduleBatchSummary()
        }
    }

    /// The phone sends files one after another, so wait for a short pause before announcing them.
    private func scheduleBatchSummary() {
        batchTask?.cancel()
        batchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, let model = self.model else { return }
            guard !self.live.values.contains(where: { $0.dir == .receive }), !self.receivedBatch.isEmpty else { return }
            let urls = self.receivedBatch
            self.receivedBatch.removeAll()
            model.showToast(urls.count == 1
                ? "Received “\(urls[0].lastPathComponent)” from phone"
                : "Received \(urls.count) files from phone")
            if model.revealAfterDownload { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    // MARK: Helpers

    private static func newKey() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<24).map { _ in chars.randomElement(using: &rng)! })
    }

    static func localIPv4(preferring preferred: [String]) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var found: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            found.append((String(cString: ifa.ifa_name), ip))
        }
        for name in preferred { if let hit = found.first(where: { $0.name == name }) { return hit.ip } }
        if let en = found.first(where: { $0.name.hasPrefix("en") }) { return en.ip }
        return found.first { !$0.name.hasPrefix("utun") && !$0.name.hasPrefix("bridge") && !$0.name.hasPrefix("awdl") }?.ip
    }

    /// Small JPEG preview for the phone page (photos, videos, PDFs…). Nil for plain files.
    static func thumbnailJPEG(_ url: URL) async -> Data? {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 320, height: 320),
                                               scale: 1, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        return NSBitmapImageRep(cgImage: rep.cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }

    static func makeQR(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let ci = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: ci.extent.width, height: ci.extent.height))
    }

    static func iconPNG(_ px: Int) -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSApp.applicationIconImage?.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
