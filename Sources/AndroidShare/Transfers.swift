import Foundation
import AppKit

@MainActor
final class Transfer: ObservableObject, Identifiable {
    enum Kind { case download, upload, open, phoneCopy, wifiReceive, wifiSend }
    enum State: Equatable { case queued, running, done, failed(String), cancelled }

    let id = UUID()
    let created = Date()
    let kind: Kind
    let name: String
    let detail: String
    @Published var state: State = .queued
    @Published var bytesDone: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var speed: Double = 0  // bytes/sec
    var resultURL: URL?

    let box = ProcessBox()
    let total: () async -> Int64
    let probe: () async -> Int64
    let work: (ProcessBox) async throws -> Void
    let completion: (@MainActor (Transfer) -> Void)?

    init(kind: Kind, name: String, detail: String,
         total: @escaping () async -> Int64,
         probe: @escaping () async -> Int64,
         work: @escaping (ProcessBox) async throws -> Void,
         completion: (@MainActor (Transfer) -> Void)? = nil) {
        self.kind = kind; self.name = name; self.detail = detail
        self.total = total; self.probe = probe; self.work = work; self.completion = completion
    }

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(bytesDone) / Double(totalBytes))
    }

    var isFinished: Bool {
        switch state { case .done, .failed, .cancelled: return true; default: return false }
    }

    var statusText: String {
        switch state {
        case .queued: return "Waiting…"
        case .running:
            var s = totalBytes > 0 ? "\(bytesDone.byteString) of \(totalBytes.byteString)" : bytesDone.byteString
            if speed > 0 {
                s += " · \(Int64(speed).byteString)/s"
                if totalBytes > bytesDone {
                    let secs = Double(totalBytes - bytesDone) / speed
                    s += " · \(Self.eta(secs)) left"
                }
            }
            return s
        case .done: return totalBytes > 0 ? "Done · \(totalBytes.byteString)" : "Done"
        case .failed(let m): return "Failed: \(m)"
        case .cancelled: return "Cancelled"
        }
    }

    private static func eta(_ s: Double) -> String {
        if s < 60 { return "\(Int(s.rounded()))s" }
        if s < 3600 { return "\(Int(s / 60))m \(Int(s.truncatingRemainder(dividingBy: 60)))s" }
        return "\(Int(s / 3600))h \(Int(s.truncatingRemainder(dividingBy: 3600) / 60))m"
    }

    var verb: String {
        switch kind {
        case .download: return "Copying to Mac"
        case .upload: return "Copying to Phone"
        case .open: return "Opening"
        case .phoneCopy: return "Copying on Phone"
        case .wifiReceive: return "Receiving over Wi-Fi"
        case .wifiSend: return "Sending over Wi-Fi"
        }
    }

    var symbol: String {
        switch kind {
        case .download: return "arrow.down.circle.fill"
        case .upload: return "arrow.up.circle.fill"
        case .open: return "eye.circle.fill"
        case .phoneCopy: return "doc.on.doc.fill"
        case .wifiReceive: return "wifi.circle.fill"
        case .wifiSend: return "wifi.circle.fill"
        }
    }
}

@MainActor
final class TransferManager: ObservableObject {
    @Published private(set) var items: [Transfer] = []
    private var running = false

    var active: Transfer? { items.first { $0.state == .running } }
    var pendingCount: Int { items.filter { $0.state == .queued || $0.state == .running }.count }

    func enqueue(_ t: Transfer) {
        items.append(t)
        pump()
    }

    /// Adds a transfer that is already running and driven from outside the queue (Wi-Fi transfers).
    func track(_ t: Transfer) {
        t.state = .running
        items.append(t)
    }

    func cancel(_ t: Transfer) {
        if t.state == .queued { t.state = .cancelled; objectWillChange.send() }
        else if t.state == .running { t.box.cancel() }
    }

    func cancelAll() { items.forEach(cancel) }

    func remove(_ t: Transfer) {
        items.removeAll { $0.id == t.id && $0.isFinished }
    }

    func clearFinished() {
        items.removeAll { $0.isFinished }
    }

    private func pump() {
        guard !running, let next = items.first(where: { $0.state == .queued }) else { return }
        running = true
        Task {
            await run(next)
            running = false
            pump()
        }
    }

    private func run(_ t: Transfer) async {
        t.state = .running
        objectWillChange.send()
        t.totalBytes = await t.total()

        let probeTask = Task { @MainActor [weak t] in
            var lastBytes: Int64 = 0
            var lastTime = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let t, !Task.isCancelled else { return }
                let b = await t.probe()
                let now = Date()
                let dt = now.timeIntervalSince(lastTime)
                if b > lastBytes, dt > 0 {
                    let inst = Double(b - lastBytes) / dt
                    t.speed = t.speed == 0 ? inst : t.speed * 0.6 + inst * 0.4
                }
                lastBytes = b; lastTime = now
                t.bytesDone = max(t.bytesDone, b)
            }
        }

        do {
            try await t.work(t.box)
            probeTask.cancel()
            if t.box.cancelled { t.state = .cancelled } else {
                t.bytesDone = max(t.bytesDone, t.totalBytes)
                t.state = .done
            }
        } catch {
            probeTask.cancel()
            t.state = t.box.cancelled ? .cancelled : .failed(error.localizedDescription)
        }
        objectWillChange.send()
        t.completion?(t)
    }
}
