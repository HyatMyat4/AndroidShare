import Foundation
import Network
import UniformTypeIdentifiers

/// A tiny HTTP/1.1 server that the phone's web browser talks to.
/// Everything runs on one serial queue; the hub on the main thread gets `Event`s.
final class WiFiServer: @unchecked Sendable {
    struct OutboxEntry: Sendable {
        let id: String
        let url: URL
        let name: String
        var thumb: Data? = nil
    }

    struct Config: Sendable {
        var key = ""
        var saveFolder = FileManager.default.homeDirectoryForCurrentUser
        var macName = "Mac"
        var outbox: [OutboxEntry] = []
        var icon192 = Data()
        var icon512 = Data()
    }

    enum Direction: Sendable { case receive, send }
    enum Outcome: Sendable { case done(URL?), failed(String), cancelled }

    enum Event: Sendable {
        case listening(UInt16)
        case failed(String)
        case phoneSeen
        case started(id: UUID, dir: Direction, name: String, size: Int64, cancel: @Sendable () -> Void)
        case progress(id: UUID, bytes: Int64)
        case finished(id: UUID, dir: Direction, outcome: Outcome)
    }

    /// Called on the server queue.
    var onEvent: (@Sendable (Event) -> Void)?

    let queue = DispatchQueue(label: "AndroidShare.WiFiServer")
    private let lock = NSLock()
    private var _config = Config()
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]

    var config: Config {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock() }
    }

    func emit(_ e: Event) { onEvent?(e) }

    // MARK: Lifecycle

    func start(preferredPort: UInt16) {
        queue.async { self.listen(port: preferredPort, attemptsLeft: 20) }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for c in self.clients.values { c.abort() }
            self.clients.removeAll()
        }
    }

    private func listen(port: UInt16, attemptsLeft: Int) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: p) else {
            if attemptsLeft > 1 { listen(port: port &+ 1, attemptsLeft: attemptsLeft - 1) }
            else { emit(.failed("Couldn't open a network port.")) }
            return
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, self.listener === l else { return }
            switch state {
            case .ready:
                self.emit(.listening(port))
            case .failed(let err):
                l.cancel()
                self.listener = nil
                if attemptsLeft > 1 { self.listen(port: port &+ 1, attemptsLeft: attemptsLeft - 1) }
                else { self.emit(.failed(err.localizedDescription)) }
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        let c = Client(conn: conn, server: self)
        clients[ObjectIdentifier(c)] = c
        c.start()
    }

    fileprivate func remove(_ c: Client) {
        clients.removeValue(forKey: ObjectIdentifier(c))
    }

    // MARK: Helpers

    static func safeName(_ raw: String) -> String {
        var n = raw.replacingOccurrences(of: "\\", with: "/")
        n = (n as NSString).lastPathComponent
        n = n.replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while n.hasPrefix(".") { n.removeFirst() }
        if n.isEmpty || n == "/" { n = "file" }
        while n.utf8.count > 200 {
            let ext = (n as NSString).pathExtension
            let base = (n as NSString).deletingPathExtension
            n = String(base.dropLast(10)) + (ext.isEmpty ? "" : "." + ext)
        }
        return n
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var i = 2
        repeat {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }
}

// MARK: - One HTTP connection

private final class Client: @unchecked Sendable {
    struct Request {
        var method = ""
        var path = ""
        var query: [String: String] = [:]
        var headers: [String: String] = [:]
    }

    let conn: NWConnection
    let server: WiFiServer
    private var buffer = Data()
    private var closed = false
    private var cancelled = false
    private var transferID: UUID?
    private var transferDir: WiFiServer.Direction = .receive
    private var lastProgress = Date.distantPast

    init(conn: NWConnection, server: WiFiServer) {
        self.conn = conn
        self.server = server
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connectionLost()
            default: break
            }
        }
        conn.start(queue: server.queue)
        readHead()
    }

    /// Stop whatever is happening (user pressed cancel on the Mac, or the server is stopping).
    func abort() {
        cancelled = true
        conn.cancel()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        conn.cancel()
        server.remove(self)
    }

    private func connectionLost() {
        if let id = transferID {
            transferID = nil
            server.emit(.finished(id: id, dir: transferDir, outcome: cancelled ? .cancelled : .failed("Connection lost")))
            cleanup?()
        }
        cleanup = nil
        close()
    }

    private var cleanup: (() -> Void)?

    // MARK: Reading the request

    private func readHead() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data([13, 10, 13, 10])) {
                let head = String(decoding: self.buffer[self.buffer.startIndex..<end.lowerBound], as: UTF8.self)
                let rest = Data(self.buffer[end.upperBound...])
                self.buffer = Data()
                guard let req = Self.parse(head) else { return self.respond(400, text: "Bad request") }
                self.route(req, leftover: rest)
            } else if error != nil || complete || self.buffer.count > 64 * 1024 {
                self.close()
            } else {
                self.readHead()
            }
        }
    }

    private static func parse(_ head: String) -> Request? {
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var r = Request()
        r.method = String(parts[0]).uppercased()
        guard let comps = URLComponents(string: "http://localhost" + String(parts[1])) else { return nil }
        r.path = comps.path
        for item in comps.queryItems ?? [] { r.query[item.name] = item.value ?? "" }
        for line in lines {
            guard let i = line.firstIndex(of: ":") else { continue }
            let k = line[..<i].trimmingCharacters(in: .whitespaces).lowercased()
            r.headers[k] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        return r
    }

    // MARK: Routing

    private func route(_ r: Request, leftover: Data) {
        let cfg = server.config
        let authorized = !cfg.key.isEmpty && (r.headers["x-androidshare-key"] == cfg.key || r.query["k"] == cfg.key)
        if authorized { server.emit(.phoneSeen) }

        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            respond(200, type: "text/html; charset=utf-8", body: Data(PhonePage.html.utf8))
        case ("GET", "/manifest.webmanifest"):
            respond(200, type: "application/manifest+json", body: Data(PhonePage.manifest.utf8))
        case ("GET", "/icon-192.png"):
            respond(200, type: "image/png", body: cfg.icon192, cache: true)
        case ("GET", "/icon-512.png"):
            respond(200, type: "image/png", body: cfg.icon512, cache: true)
        case ("GET", "/sw.js"):
            respond(200, type: "text/javascript; charset=utf-8", body: Data(PhonePage.serviceWorker.utf8))
        case ("GET", "/favicon.ico"):
            respond(200, type: "image/png", body: cfg.icon192, cache: true)
        case (_, let p) where p.hasPrefix("/api/") && !authorized:
            respond(401, json: ["error": "not paired"])
        case ("GET", "/api/info"):
            let files: [[String: Any]] = cfg.outbox.map { e in
                let size = (try? e.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return ["id": e.id, "name": e.name, "size": size, "thumb": e.thumb != nil]
            }
            respond(200, json: ["name": cfg.macName, "folder": cfg.saveFolder.lastPathComponent, "outbox": files])
        case ("POST", "/api/upload"):
            receiveUpload(r, leftover: leftover, cfg: cfg)
        case ("GET", let p) where p.hasPrefix("/api/thumb/"):
            let id = String(p.dropFirst("/api/thumb/".count))
            guard let t = cfg.outbox.first(where: { $0.id == id })?.thumb else { return respond(404, text: "") }
            respond(200, type: "image/jpeg", body: t, cache: true)
        case ("GET", let p) where p.hasPrefix("/api/file/"):
            let id = String(p.dropFirst("/api/file/".count))
            guard let entry = cfg.outbox.first(where: { $0.id == id }) else { return respond(404, text: "File no longer offered") }
            sendFile(entry)
        default:
            respond(404, text: "Not found")
        }
    }

    // MARK: Phone → Mac

    private func receiveUpload(_ r: Request, leftover: Data, cfg: WiFiServer.Config) {
        guard let len = r.headers["content-length"].flatMap(Int64.init), len >= 0 else {
            return respond(411, json: ["error": "Missing length"])
        }
        let fm = FileManager.default
        let folder = cfg.saveFolder
        let name = WiFiServer.safeName(r.query["name"] ?? "file")
        let tmp = folder.appendingPathComponent(".androidshare-\(UUID().uuidString).part")
        let handle: FileHandle
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard fm.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
            handle = try FileHandle(forWritingTo: tmp)
        } catch {
            return respond(500, json: ["error": "Mac can't save to \(folder.lastPathComponent)"])
        }

        let id = UUID()
        transferID = id
        transferDir = .receive
        cleanup = { try? handle.close(); try? fm.removeItem(at: tmp) }
        server.emit(.started(id: id, dir: .receive, name: name, size: len, cancel: { [weak self] in
            guard let self else { return }
            self.server.queue.async { self.abort() }
        }))

        var received: Int64 = 0

        func write(_ d: Data) -> Bool {
            let chunk = Int64(d.count) > len - received ? d.prefix(Int(len - received)) : d
            do { try handle.write(contentsOf: chunk) } catch { return false }
            received += Int64(chunk.count)
            reportProgress(received, force: received >= len)
            return true
        }

        func finish() {
            transferID = nil
            cleanup = nil
            do {
                try handle.close()
                let dest = WiFiServer.uniqueURL(in: folder, name: name)
                try fm.moveItem(at: tmp, to: dest)
                if let ms = r.query["mtime"].flatMap(Double.init), ms > 0 {
                    try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: ms / 1000)], ofItemAtPath: dest.path)
                }
                server.emit(.finished(id: id, dir: .receive, outcome: .done(dest)))
                respond(200, json: ["ok": true, "name": dest.lastPathComponent])
            } catch {
                try? fm.removeItem(at: tmp)
                server.emit(.finished(id: id, dir: .receive, outcome: .failed(error.localizedDescription)))
                respond(500, json: ["error": "Mac couldn't save the file"])
            }
        }

        func fail(_ message: String) {
            transferID = nil
            cleanup?()
            cleanup = nil
            server.emit(.finished(id: id, dir: .receive, outcome: cancelled ? .cancelled : .failed(message)))
            close()
        }

        if !leftover.isEmpty, !write(leftover) { return fail("Disk write failed") }
        if received >= len { return finish() }

        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
                guard let self, self.transferID == id else { return }
                if self.cancelled { return fail("Cancelled") }
                if let data, !data.isEmpty, !write(data) { return fail("Disk write failed (is the disk full?)") }
                if received >= len { return finish() }
                if error != nil || complete { return fail("Phone disconnected") }
                readMore()
            }
        }
        readMore()
    }

    // MARK: Mac → Phone

    private func sendFile(_ entry: WiFiServer.OutboxEntry) {
        guard let handle = try? FileHandle(forReadingFrom: entry.url),
              let size = (try? FileManager.default.attributesOfItem(atPath: entry.url.path)[.size] as? NSNumber)?.int64Value
        else { return respond(404, text: "File is missing on the Mac") }

        let mime = UTType(filenameExtension: entry.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let ascii = String(entry.name.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0.value >= 32 ? Character($0) : "_" })
        let encoded = entry.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ascii
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: \(mime)\r\n"
            + "Content-Length: \(size)\r\n"
            + "Content-Disposition: attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"

        let id = UUID()
        transferID = id
        transferDir = .send
        cleanup = { try? handle.close() }
        server.emit(.started(id: id, dir: .send, name: entry.name, size: size, cancel: { [weak self] in
            guard let self else { return }
            self.server.queue.async { self.abort() }
        }))

        var sent: Int64 = 0
        func pump() {
            guard transferID == id, !cancelled else { return }
            let chunk = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
            if chunk.isEmpty {
                transferID = nil
                cleanup?()
                cleanup = nil
                server.emit(.finished(id: id, dir: .send, outcome: sent >= size ? .done(entry.url) : .failed("File changed while sending")))
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    self?.close()
                })
                return
            }
            conn.send(content: chunk, completion: .contentProcessed { [weak self] err in
                guard let self, self.transferID == id else { return }
                if err != nil { return self.connectionLost() }
                sent += Int64(chunk.count)
                self.reportProgress(sent, force: false)
                pump()
            })
        }

        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { self?.connectionLost() } else { pump() }
        })
    }

    private func reportProgress(_ bytes: Int64, force: Bool) {
        guard let id = transferID else { return }
        let now = Date()
        if force || now.timeIntervalSince(lastProgress) > 0.2 {
            lastProgress = now
            server.emit(.progress(id: id, bytes: bytes))
        }
    }

    // MARK: Responses

    private func respond(_ status: Int, text: String) {
        respond(status, type: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    private func respond(_ status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        respond(status, type: "application/json", body: body)
    }

    private func respond(_ status: Int, type: String, body: Data, cache: Bool = false) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 411: reason = "Length Required"
        default: reason = "Error"
        }
        var out = Data(("HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(type)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + (cache ? "Cache-Control: max-age=86400\r\n" : "Cache-Control: no-store\r\n")
            + "Connection: close\r\n\r\n").utf8)
        out.append(body)
        conn.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }
}
