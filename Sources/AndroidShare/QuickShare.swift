import Foundation
import Network
import CryptoKit
import CommonCrypto

/// Receives files from Android's built-in Quick Share (Google / Samsung "Quick Share", formerly Nearby Share).
///
/// The Mac advertises itself over Bonjour exactly like a Quick Share computer, so it appears in the
/// phone's share sheet. Protocol: Nearby Connections (offline_wire_formats.proto) + UKEY2 handshake +
/// D2D SecureMessage encryption + Nearby Sharing frames (wire_format.proto).
final class QuickShareServer: @unchecked Sendable {
    static let serviceType = "_FC9F5ED42C8A._tcp"

    struct Config: Sendable {
        var deviceName = "Mac"
        var saveFolder = FileManager.default.homeDirectoryForCurrentUser
    }

    struct IncomingFile: Sendable { let name: String; let size: Int64 }

    struct Request: Sendable {
        let device: String
        let pin: String
        let files: [IncomingFile]
        let textTitles: [String]
        let respond: @Sendable (Bool) -> Void
    }

    enum Event: Sendable {
        case ready
        case failed(String)
        case request(Request)
        case transfer(WiFiServer.Event)
        case text(String, isURL: Bool, from: String)
    }

    var onEvent: (@Sendable (Event) -> Void)?
    let queue = DispatchQueue(label: "AndroidShare.QuickShare")

    private let lock = NSLock()
    private var _config = Config()
    var config: Config {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock() }
    }

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: QSConnection] = [:]
    private let endpointID: Data = {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
        return Data((0..<4).map { _ in chars.randomElement()! })
    }()

    func emit(_ e: Event) { onEvent?(e) }

    func start() {
        queue.async { self.listen() }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for c in self.connections.values { c.abort() }
            self.connections.removeAll()
        }
    }

    private func listen() {
        // Bonjour instance name: 0x23, 4-byte endpoint id, service-id hash FC 9F 5E, two zero bytes.
        var nameBytes = Data([0x23])
        nameBytes.append(endpointID)
        nameBytes.append(contentsOf: [0xFC, 0x9F, 0x5E, 0x00, 0x00])

        // TXT "n": device type (computer = 3) << 1, 16 random bytes, name length, name.
        var info = Data([3 << 1])
        info.append(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let name = Data(config.deviceName.utf8.prefix(200))
        info.append(UInt8(name.count))
        info.append(name)

        let params = NWParameters.tcp
        params.includePeerToPeer = false
        guard let l = try? NWListener(using: params) else { return emit(.failed("Couldn't open a network port.")) }
        var txt = NWTXTRecord()
        txt["n"] = info.base64URL
        l.service = NWListener.Service(name: nameBytes.base64URL, type: Self.serviceType, domain: nil, txtRecord: txt)
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let c = QSConnection(conn: conn, server: self)
            self.connections[ObjectIdentifier(c)] = c
            c.start()
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, self.listener === l else { return }
            switch state {
            case .ready: self.emit(.ready)
            case .failed(let e):
                l.cancel()
                self.listener = nil
                self.emit(.failed(e.localizedDescription))
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    fileprivate func remove(_ c: QSConnection) {
        connections.removeValue(forKey: ObjectIdentifier(c))
    }
}

// MARK: - Debug log (~/Library/Logs/AndroidShare/quickshare.log)

enum QSLog {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AndroidShare")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("quickshare.log")
    }()
    private static let q = DispatchQueue(label: "QSLog")
    static func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
    static func hex(_ d: Data, max: Int = 160) -> String {
        d.prefix(max).map { String(format: "%02x", $0) }.joined() + (d.count > max ? "…(\(d.count) bytes)" : "")
    }
}

// MARK: - One incoming Quick Share session

private final class QSConnection: @unchecked Sendable {
    enum Stage { case connectionRequest, clientInit, clientFinish, connectionResponse, encrypted }

    private struct FileState {
        let transferID = UUID()
        let name: String
        let size: Int64
        let tmp: URL
        let handle: FileHandle
        var received: Int64 = 0
        var lastProgress = Date.distantPast
        var done = false
    }

    let conn: NWConnection
    let server: QuickShareServer
    private var stage = Stage.connectionRequest
    private var closed = false
    private var cancelled = false

    private var remoteName = "Android phone"
    private var clientInitRaw = Data()
    private var serverInitRaw = Data()
    private var commitment = Data()
    private let privateKey = P256.KeyAgreement.PrivateKey()

    private var decryptKey = Data(), recvHmacKey = SymmetricKey(size: .bits256)
    private var encryptKey = Data(), sendHmacKey = SymmetricKey(size: .bits256)
    private var pin = ""
    private var seqOut: Int32 = 0

    private var bytesPayloads: [Int64: Data] = [:]
    private var files: [Int64: FileState] = [:]
    private var textPayloads: [Int64: (title: String, isURL: Bool)] = [:]
    private var accepted = false
    private var finishedAll = false

    init(conn: NWConnection, server: QuickShareServer) {
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
        QSLog.log("connection from \(conn.endpoint)")
        readFrame()
    }

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

    /// Clean up any half-received files.
    private func connectionLost() {
        if !closed { QSLog.log("connection closed at stage \(stage) cancelled=\(cancelled)") }
        for (id, f) in files where !f.done {
            try? f.handle.close()
            try? FileManager.default.removeItem(at: f.tmp)
            server.emit(.transfer(.finished(id: f.transferID, dir: .receive,
                                            outcome: cancelled ? .cancelled : .failed("Phone disconnected"))))
            files[id]?.done = true
        }
        close()
    }

    // MARK: Framing (4-byte big-endian length + body)

    private func readFrame() {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard let data, data.count == 4, error == nil else {
                QSLog.log("read header failed: \(String(describing: error)) complete=\(complete)")
                return self.connectionLost()
            }
            let len = data.reduce(0) { $0 << 8 | Int($1) }
            guard len > 0, len < 32 << 20 else { return self.connectionLost() }
            self.conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] body, _, _, error in
                guard let self, !self.closed else { return }
                guard let body, body.count == len, error == nil else { return self.connectionLost() }
                if self.stage != .encrypted { QSLog.log("recv stage=\(self.stage) \(QSLog.hex(body))") }
                do {
                    try self.handle(body)
                    if !self.closed { self.readFrame() }
                } catch {
                    QSLog.log("ERROR at stage \(self.stage): \(error)")
                    self.connectionLost()
                }
            }
            _ = complete
        }
    }

    private func sendFrame(_ data: Data, then: (() -> Void)? = nil) {
        if stage != .encrypted { QSLog.log("send stage=\(stage) \(QSLog.hex(data))") }
        var len = UInt32(data.count).bigEndian
        var out = Data(bytes: &len, count: 4)
        out.append(data)
        conn.send(content: out, completion: .contentProcessed { _ in then?() })
    }

    struct ProtocolError: Error {}

    // MARK: Handshake

    private func handle(_ frame: Data) throws {
        switch stage {
        case .connectionRequest:
            // OfflineFrame.v1.connection_request.endpoint_info → device name
            let req = try ProtoMessage(frame).message(2)?.message(2)
            if let info = req?.bytes(6), info.count >= 18 {
                let b = [UInt8](info)
                let n = Int(b[17])
                if b.count >= 18 + n, n > 0 { remoteName = String(decoding: b[18..<(18 + n)], as: UTF8.self) }
            } else if let n = req?.string(2), !n.isEmpty {
                remoteName = n
            }
            stage = .clientInit

        case .clientInit:
            let msg = try ProtoMessage(frame)
            guard msg.int(1) == 2, let initData = msg.bytes(2) else { throw ProtocolError() }
            let ci = try ProtoMessage(initData)
            guard let c = ci.messages(3).first(where: { $0.int(1) == 100 }), let commit = c.bytes(2) else {
                throw ProtocolError()   // phone didn't offer P256_SHA512
            }
            clientInitRaw = frame
            commitment = commit

            let raw = privateKey.publicKey.x963Representation   // 04 || X || Y
            let pub = ProtoWriter.build { k in
                k.int(1, 1)   // EC_P256
                k.message(2) { e in
                    e.bytes(1, Data([0]) + raw.subdata(in: 1..<33))   // leading 0 so Java BigInteger stays positive
                    e.bytes(2, Data([0]) + raw.subdata(in: 33..<65))
                }
            }
            let serverInit = ProtoWriter.build { s in
                s.int(1, 1)
                s.bytes(2, Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
                s.int(3, 100)   // P256_SHA512
                s.bytes(4, pub)
            }
            serverInitRaw = ProtoWriter.build { m in
                m.int(1, 3)   // SERVER_INIT
                m.bytes(2, serverInit)
            }
            sendFrame(serverInitRaw)
            stage = .clientFinish

        case .clientFinish:
            guard Data(SHA512.hash(data: frame)) == commitment else { throw ProtocolError() }
            let msg = try ProtoMessage(frame)
            guard msg.int(1) == 4, let fin = msg.message(2), let keyData = fin.bytes(1) else { throw ProtocolError() }
            let key = try ProtoMessage(keyData)
            guard let ec = key.message(2), let x = ec.bytes(1), let y = ec.bytes(2) else { throw ProtocolError() }
            var x963 = Data([4])
            x963.append(Self.fixed32(x))
            x963.append(Self.fixed32(y))
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: x963)
            try deriveKeys(peer)
            stage = .connectionResponse

        case .connectionResponse:
            let frameMsg = try ProtoMessage(frame)
            guard frameMsg.message(2)?.int(1) == 2 else { throw ProtocolError() }
            let resp = ProtoWriter.build { f in
                f.int(1, 1)   // V1
                f.message(2) { v in
                    v.int(1, 2)   // CONNECTION_RESPONSE
                    v.message(3) { r in
                        r.int(1, 0)   // status OK
                        r.int(3, 1)   // ACCEPT
                        r.message(4) { $0.int(1, 4) }   // os_info: APPLE
                    }
                }
            }
            sendFrame(resp)
            stage = .encrypted
            // The receiver speaks first once encryption is up.
            sendPairedKeyEncryption()

        case .encrypted:
            try handleOfflineFrame(try decrypt(frame))
        }
    }

    private static func fixed32(_ d: Data) -> Data {
        var b = [UInt8](d)
        while b.count > 32, b.first == 0 { b.removeFirst() }
        if b.count < 32 { b = [UInt8](repeating: 0, count: 32 - b.count) + b }
        return Data(b)
    }

    private func deriveKeys(_ peer: P256.KeyAgreement.PublicKey) throws {
        let dhs = try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        let derived = SymmetricKey(data: Data(SHA256.hash(data: dhs)))
        let info = clientInitRaw + serverInitRaw
        let auth = HKDF<SHA256>.deriveKey(inputKeyMaterial: derived, salt: Data("UKEY2 v1 auth".utf8), info: info, outputByteCount: 32)
        let next = HKDF<SHA256>.deriveKey(inputKeyMaterial: derived, salt: Data("UKEY2 v1 next".utf8), info: info, outputByteCount: 32)

        // PIN shown on both devices
        var hash = 0, mult = 1
        auth.withUnsafeBytes { raw in
            for byte in raw {
                hash = (hash + Int(Int8(bitPattern: byte)) * mult) % 9973
                mult = (mult * 31) % 9973
            }
        }
        pin = String(format: "%04d", abs(hash))

        let d2dSalt = Data(SHA256.hash(data: Data("D2D".utf8)))
        let smsgSalt = Data(SHA256.hash(data: Data("SecureMessage".utf8)))
        func hkdf(_ k: SymmetricKey, _ salt: Data, _ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: k, salt: salt, info: Data(info.utf8), outputByteCount: 32)
        }
        let client = hkdf(next, d2dSalt, "client")
        let serverK = hkdf(next, d2dSalt, "server")
        decryptKey = hkdf(client, smsgSalt, "ENC:2").withUnsafeBytes { Data($0) }
        recvHmacKey = hkdf(client, smsgSalt, "SIG:1")
        encryptKey = hkdf(serverK, smsgSalt, "ENC:2").withUnsafeBytes { Data($0) }
        sendHmacKey = hkdf(serverK, smsgSalt, "SIG:1")
    }

    // MARK: Encryption (SecureMessage, AES-256-CBC + HMAC-SHA256)

    private func decrypt(_ frame: Data) throws -> ProtoMessage {
        let smsg = try ProtoMessage(frame)
        guard let hab = smsg.bytes(1), let sig = smsg.bytes(2),
              HMAC<SHA256>.isValidAuthenticationCode(sig, authenticating: hab, using: recvHmacKey)
        else { throw ProtocolError() }
        let hb = try ProtoMessage(hab)
        guard let iv = hb.message(1)?.bytes(5), let body = hb.bytes(2),
              let plain = Self.aes(CCOperation(kCCDecrypt), key: decryptKey, iv: iv, data: body)
        else { throw ProtocolError() }
        let d2d = try ProtoMessage(plain)
        guard let offline = d2d.bytes(1) else { throw ProtocolError() }
        return try ProtoMessage(offline)
    }

    private func sendEncrypted(_ offlineFrame: Data, then: (() -> Void)? = nil) {
        seqOut += 1
        let d2d = ProtoWriter.build { $0.bytes(1, offlineFrame); $0.int(2, Int64(seqOut)) }
        let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        guard let body = Self.aes(CCOperation(kCCEncrypt), key: encryptKey, iv: iv, data: d2d) else { return }
        let metadata = ProtoWriter.build { $0.int(1, 13); $0.int(2, 1) }   // DEVICE_TO_DEVICE_MESSAGE, v1
        let header = ProtoWriter.build { h in
            h.int(1, 1)   // HMAC_SHA256
            h.int(2, 2)   // AES_256_CBC
            h.bytes(5, iv)
            h.bytes(6, metadata)
        }
        let hab = ProtoWriter.build { $0.bytes(1, header); $0.bytes(2, body) }
        let sig = Data(HMAC<SHA256>.authenticationCode(for: hab, using: sendHmacKey))
        sendFrame(ProtoWriter.build { $0.bytes(1, hab); $0.bytes(2, sig) }, then: then)
    }

    private static func aes(_ op: CCOperation, key: Data, iv: Data, data: Data) -> Data? {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCap = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress,
                                d.baseAddress, data.count, o.baseAddress, outCap, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    // MARK: Nearby Connections frames

    private func handleOfflineFrame(_ frame: ProtoMessage) throws {
        guard let v1 = frame.message(2) else { return }
        if v1.int(1) != 3 || v1.message(4)?.message(2)?.int(2) != 2 { QSLog.log("offline frame type=\(v1.int(1) ?? -1)") }
        switch v1.int(1) {
        case 3:   // PAYLOAD_TRANSFER
            guard let pt = v1.message(4) else { return }
            if pt.int(1) == 2 {   // CONTROL
                if pt.message(4)?.int(1) == 1 { cancelled = true; connectionLost() }   // PAYLOAD_CANCELED
                return
            }
            guard let header = pt.message(2), let chunk = pt.message(3), let id = header.int(1) else { return }
            let body = chunk.bytes(3) ?? Data()
            let last = ((chunk.int(1) ?? 0) & 1) != 0
            if header.int(2) == 2 {   // FILE
                try receiveFileChunk(id: id, offset: chunk.int(2) ?? 0, body: body, last: last)
            } else {   // BYTES
                bytesPayloads[id, default: Data()].append(body)
                if last, let payload = bytesPayloads.removeValue(forKey: id) {
                    if let t = textPayloads.removeValue(forKey: id) {
                        let text = String(decoding: payload, as: UTF8.self)
                        server.emit(.text(text, isURL: t.isURL, from: remoteName))
                        checkAllDone()
                    } else {
                        try handleSharingFrame(try ProtoMessage(payload))
                    }
                }
            }

        case 5:   // KEEP_ALIVE
            sendEncrypted(ProtoWriter.build { f in
                f.int(1, 1)
                f.message(2) { v in v.int(1, 5); v.message(6) { $0.bool(1, true) } }
            })

        case 6:   // DISCONNECTION
            connectionLost()

        default:
            break   // bandwidth upgrade etc. are not needed; stay on the LAN connection
        }
    }

    // MARK: Nearby Sharing frames

    private func sendSharingFrame(_ build: (inout ProtoWriter) -> Void, then: (() -> Void)? = nil) {
        let frame = ProtoWriter.build { f in
            f.int(1, 1)
            f.message(2, build)
        }
        let id = Int64.random(in: 1...Int64.max)
        func payload(offset: Int, flags: Int, body: Data?) -> Data {
            ProtoWriter.build { o in
                o.int(1, 1)
                o.message(2) { v in
                    v.int(1, 3)   // PAYLOAD_TRANSFER
                    v.message(4) { p in
                        p.int(1, 1)   // DATA
                        p.message(2) { h in h.int(1, id); h.int(2, 1); h.int(3, frame.count); h.bool(4, false) }
                        p.message(3) { c in
                            c.int(1, flags)
                            c.int(2, offset)
                            if let body { c.bytes(3, body) }
                        }
                    }
                }
            }
        }
        sendEncrypted(payload(offset: 0, flags: 0, body: frame))
        sendEncrypted(payload(offset: frame.count, flags: 1, body: nil), then: then)
    }

    private func handleSharingFrame(_ frame: ProtoMessage) throws {
        guard let v1 = frame.message(2) else { return }
        QSLog.log("sharing frame type=\(v1.int(1) ?? -1)")
        switch v1.int(1) {
        case 3:   // PAIRED_KEY_ENCRYPTION from phone → we can't verify contacts, answer UNABLE
            sendSharingFrame { v in
                v.int(1, 4)
                v.message(5) { $0.int(1, 3) }   // PAIRED_KEY_RESULT: UNABLE
            }
        case 4:   // PAIRED_KEY_RESULT from phone → wait for the introduction
            break
        case 1:   // INTRODUCTION
            guard let intro = v1.message(2) else { return }
            handleIntroduction(intro)
        case 6:   // CANCEL
            cancelled = true
            connectionLost()
        default:
            break
        }
    }

    /// Random data: we have no Google-account contact keys, which is fine for "Everyone" mode.
    private func sendPairedKeyEncryption() {
        sendSharingFrame { v in
            v.int(1, 3)
            v.message(4) { p in
                p.bytes(1, Data((0..<72).map { _ in UInt8.random(in: 0...255) }))
                p.bytes(2, Data((0..<6).map { _ in UInt8.random(in: 0...255) }))
            }
        }
    }

    private func handleIntroduction(_ intro: ProtoMessage) {
        let fileMetas = intro.messages(1)
        let textMetas = intro.messages(2)
        guard !fileMetas.isEmpty || !textMetas.isEmpty else {
            return respond(accept: false)   // e.g. Wi-Fi credentials: not supported
        }

        var pending: [(id: Int64, name: String, size: Int64)] = []
        for m in fileMetas {
            guard let id = m.int(3) else { continue }
            pending.append((id, WiFiServer.safeName(m.string(1) ?? "file"), m.int(4) ?? 0))
        }
        for t in textMetas {
            guard let id = t.int(4) else { continue }
            textPayloads[id] = (t.string(2) ?? "Text", t.int(3) == 2)
        }

        let request = QuickShareServer.Request(
            device: remoteName,
            pin: pin,
            files: pending.map { .init(name: $0.name, size: $0.size) },
            textTitles: textMetas.compactMap { $0.string(2) },
            respond: { [weak self] ok in
                guard let self else { return }
                self.server.queue.async {
                    guard !self.closed else { return }
                    if ok { self.prepareFiles(pending) } else { self.respond(accept: false) }
                }
            })
        server.emit(.request(request))
    }

    private func prepareFiles(_ pending: [(id: Int64, name: String, size: Int64)]) {
        let folder = server.config.saveFolder
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for p in pending {
                let tmp = folder.appendingPathComponent(".androidshare-\(UUID().uuidString).part")
                guard fm.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
                let f = FileState(name: p.name, size: p.size, tmp: tmp, handle: try FileHandle(forWritingTo: tmp))
                files[p.id] = f
                let tid = f.transferID
                server.emit(.transfer(.started(id: tid, dir: .receive, name: p.name, size: p.size, cancel: { [weak self] in
                    guard let self else { return }
                    self.server.queue.async {
                        self.sendSharingFrame({ $0.int(1, 6) }, then: { self.abort() })
                    }
                })))
            }
        } catch {
            connectionLost()
            return
        }
        accepted = true
        respond(accept: true)
        checkAllDone()
    }

    private func respond(accept: Bool) {
        sendSharingFrame({ v in
            v.int(1, 2)   // RESPONSE
            v.message(3) { $0.int(1, accept ? 1 : 2) }
        }, then: accept ? nil : { [weak self] in self?.disconnect() })
    }

    private func receiveFileChunk(id: Int64, offset: Int64, body: Data, last: Bool) throws {
        guard accepted, var f = files[id], !f.done else { return }
        if !body.isEmpty {
            try f.handle.seek(toOffset: UInt64(offset))
            try f.handle.write(contentsOf: body)
            f.received = max(f.received, offset + Int64(body.count))
        }
        let now = Date()
        if last || now.timeIntervalSince(f.lastProgress) > 0.2 {
            f.lastProgress = now
            server.emit(.transfer(.progress(id: f.transferID, bytes: f.received)))
        }
        if last {
            f.done = true
            try? f.handle.close()
            let dest = WiFiServer.uniqueURL(in: server.config.saveFolder, name: f.name)
            do {
                try FileManager.default.moveItem(at: f.tmp, to: dest)
                server.emit(.transfer(.finished(id: f.transferID, dir: .receive, outcome: .done(dest))))
            } catch {
                try? FileManager.default.removeItem(at: f.tmp)
                server.emit(.transfer(.finished(id: f.transferID, dir: .receive, outcome: .failed(error.localizedDescription))))
            }
        }
        files[id] = f
        checkAllDone()
    }

    private func checkAllDone() {
        guard accepted, !finishedAll, files.values.allSatisfy(\.done), textPayloads.isEmpty else { return }
        finishedAll = true
        disconnect()
    }

    private func disconnect() {
        sendEncrypted(ProtoWriter.build { f in
            f.int(1, 1)
            f.message(2) { v in v.int(1, 6); v.message(7) { _ in } }
        }, then: { [weak self] in self?.close() })
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
