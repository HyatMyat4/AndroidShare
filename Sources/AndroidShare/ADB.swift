import Foundation

// MARK: - Process runner

struct ProcResult {
    var status: Int32
    var out: Data
    var err: Data
    var stdout: String { String(decoding: out, as: UTF8.self) }
    var stderr: String { String(decoding: err, as: UTF8.self) }
}

/// Holds a running process so a transfer can be cancelled.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var cancelled = false

    func attach(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        process = p
        if cancelled { p.terminate() }
    }

    private var cancelHandler: (() -> Void)?

    /// Runs `handler` when the transfer is cancelled (used by Wi-Fi transfers, which have no Process).
    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); handler(); return }
        cancelHandler = handler
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        process?.terminate()
        let h = cancelHandler
        cancelHandler = nil
        lock.unlock()
        h?()
    }
}

enum Shell {
    static func run(_ exe: String, _ args: [String], box: ProcessBox? = nil, discardOutput: Bool = false) async throws -> ProcResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                if discardOutput {
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                    do { try p.run() } catch { cont.resume(throwing: error); return }
                    box?.attach(p)
                    p.waitUntilExit()
                    cont.resume(returning: ProcResult(status: p.terminationStatus, out: Data(), err: Data()))
                    return
                }
                let o = Pipe(), e = Pipe()
                p.standardOutput = o
                p.standardError = e
                do { try p.run() } catch { cont.resume(throwing: error); return }
                box?.attach(p)
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = e.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = o.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: ProcResult(status: p.terminationStatus, out: outData, err: errData))
            }
        }
    }
}

/// Single-quote a string for the Android (mksh) shell.
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum ADBError: LocalizedError {
    case failed(String)
    case folderMissing
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .failed(let m): return m
        case .folderMissing: return "This folder no longer exists on the phone."
        case .permissionDenied: return "Android doesn't allow access to this folder."
        }
    }
}

// MARK: - ADB wrapper

struct ADB: Sendable {
    let path: String

    static func locate(custom: String?) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let c = custom, !c.isEmpty { candidates.append((c as NSString).expandingTildeInPath) }
        let home = NSHomeDirectory()
        candidates += [
            "/opt/homebrew/bin/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "/opt/homebrew/Caskroom/android-platform-tools/latest/platform-tools/adb",
            "/usr/local/bin/adb",
            "/usr/local/share/android-commandlinetools/platform-tools/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "\(home)/Android/sdk/platform-tools/adb",
        ]
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("platform-tools/adb").path {
            candidates.insert(bundled, at: custom == nil ? 0 : 1)
        }
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        // Glob for versioned cask installs
        if let items = try? fm.contentsOfDirectory(atPath: "/opt/homebrew/Caskroom/android-platform-tools") {
            for v in items {
                let p = "/opt/homebrew/Caskroom/android-platform-tools/\(v)/platform-tools/adb"
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    func startServer() async {
        _ = try? await Shell.run(path, ["start-server"], discardOutput: true)
    }

    func devices() async throws -> [Device] {
        let r = try await Shell.run(path, ["devices", "-l"])
        var result: [Device] = []
        for line in r.stdout.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty || s.hasPrefix("List of devices") || s.hasPrefix("*") { continue }
            let tokens = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2 else { continue }
            var info: [String: String] = [:]
            for t in tokens.dropFirst(2) {
                let kv = t.split(separator: ":", maxSplits: 1).map(String.init)
                if kv.count == 2 { info[kv[0]] = kv[1] }
            }
            result.append(Device(serial: tokens[0], state: tokens[1],
                                 model: info["model"]?.replacingOccurrences(of: "_", with: " ") ?? tokens[0]))
        }
        return result
    }

    @discardableResult
    func shell(_ serial: String, _ cmd: String) async throws -> ProcResult {
        try await Shell.run(path, ["-s", serial, "shell", cmd])
    }

    /// Runs a shell command and throws on non-zero exit.
    func shellChecked(_ serial: String, _ cmd: String) async throws -> String {
        let r = try await shell(serial, cmd)
        if r.status != 0 {
            let msg = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ADBError.failed(msg.isEmpty ? "Command failed on the phone." : msg)
        }
        return r.stdout
    }

    // MARK: Listing

    func list(_ serial: String, dir: String, showHidden: Bool) async throws -> [RemoteFile] {
        let globs = showHidden ? "./* ./.[!.]* ./..?*" : "./*"
        let cmd = "[ -d \(shq(dir)) ] || exit 3; cd \(shq(dir)) 2>/dev/null || exit 4; "
            + "stat -L -c '%f|%s|%Y|%n' \(globs) 2>/dev/null; exit 0"
        let r = try await shell(serial, cmd)
        if r.status == 3 { throw ADBError.folderMissing }
        if r.status == 4 { throw ADBError.permissionDenied }
        if r.status != 0 { throw ADBError.failed(r.stderr.isEmpty ? "Could not read folder." : r.stderr) }
        return Self.parseListing(r.stdout, dir: dir)
    }

    static func parseListing(_ text: String, dir: String) -> [RemoteFile] {
        var files: [RemoteFile] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4,
                  let mode = UInt32(parts[0], radix: 16),
                  let size = Int64(parts[1]),
                  let mtime = Double(parts[2]) else { continue }
            var name = String(parts[3])
            if name.hasPrefix("./") { name.removeFirst(2) }
            if name.isEmpty || name == "." || name == ".." { continue }
            let isDir = (mode & 0xF000) == 0x4000
            files.append(RemoteFile(path: RemotePath.join(dir, name), name: name, isDir: isDir,
                                    size: isDir ? 0 : size, modified: Date(timeIntervalSince1970: mtime)))
        }
        return files
    }

    /// Cheap fingerprint of a directory: changes whenever entries are added, removed or renamed.
    func dirFingerprint(_ serial: String, dir: String) async -> String? {
        guard let r = try? await shell(serial, "stat -L -c '%y|%h' \(shq(dir)) 2>/dev/null || echo MISSING") else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func exists(_ serial: String, _ path: String) async -> Bool {
        (try? await shell(serial, "[ -e \(shq(path)) ]"))?.status == 0
    }

    // MARK: File ops

    func mkdir(_ serial: String, _ path: String) async throws {
        _ = try await shellChecked(serial, "mkdir -p \(shq(path))")
    }

    func move(_ serial: String, from: String, to: String) async throws {
        _ = try await shellChecked(serial, "mv \(shq(from)) \(shq(to))")
    }

    func copy(_ serial: String, from: String, to: String) async throws {
        _ = try await shellChecked(serial, "cp -r \(shq(from)) \(shq(to))")
    }

    func delete(_ serial: String, _ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await shellChecked(serial, "rm -rf " + paths.map(shq).joined(separator: " "))
    }

    /// Ask Android's media scanner to pick up changes so they show in Gallery / other apps.
    func mediaScan(_ serial: String, _ paths: [String]) async {
        guard !paths.isEmpty else { return }
        let list = paths.map(shq).joined(separator: " ")
        let cmd = "for p in \(list); do if [ -d \"$p\" ]; then find \"$p\" -type f; else echo \"$p\"; fi; done | "
            + "while IFS= read -r f; do am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \"file://$f\" >/dev/null 2>&1; done"
        _ = try? await shell(serial, cmd)
    }

    func remoteSize(_ serial: String, _ path: String, isDir: Bool) async -> Int64 {
        let cmd = isDir ? "du -sk \(shq(path)) 2>/dev/null" : "stat -c %s \(shq(path)) 2>/dev/null"
        guard let r = try? await shell(serial, cmd) else { return 0 }
        let first = r.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
        let n = Int64(first) ?? 0
        return isDir ? n * 1024 : n
    }

    func deviceName(_ serial: String) async -> String? {
        let r = try? await shell(serial, "settings get global device_name 2>/dev/null")
        let s = r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (s.isEmpty || s == "null") ? nil : s
    }

    func storage(_ serial: String, path: String) async -> StorageInfo? {
        guard let r = try? await shell(serial, "df -k \(shq(path)) 2>/dev/null | tail -n 1") else { return nil }
        let t = r.stdout.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        guard t.count >= 4, let total = Int64(t[1]), let used = Int64(t[2]) else { return nil }
        return StorageInfo(total: total * 1024, used: used * 1024)
    }

    func existingDirs(_ serial: String, root: String, candidates: [String]) async -> Set<String> {
        let list = candidates.map(shq).joined(separator: " ")
        let cmd = "cd \(shq(root)) 2>/dev/null || exit 0; for d in \(list); do [ -d \"$d\" ] && echo \"$d\"; done; exit 0"
        guard let r = try? await shell(serial, cmd) else { return [] }
        return Set(r.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// Extra storage volumes like SD cards or USB drives (e.g. /storage/1A2B-3C4D).
    func externalVolumes(_ serial: String) async -> [String] {
        guard let r = try? await shell(serial, "ls /storage 2>/dev/null") else { return [] }
        return r.stdout.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { $0.range(of: #"^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$"#, options: .regularExpression) != nil }
            .map { "/storage/\($0)" }
    }

    // MARK: Transfers

    func pull(_ serial: String, remote: String, local: String, box: ProcessBox? = nil) async throws {
        let r = try await Shell.run(path, ["-s", serial, "pull", "-a", remote, local], box: box)
        if r.status != 0 {
            throw ADBError.failed(Self.cleanError(r))
        }
    }

    /// Reads a byte range of a phone file without copying the whole thing (used for video previews).
    func readRange(_ serial: String, remote: String, offset: Int64, length: Int64) async throws -> Data {
        let bs: Int64 = 65536
        let skip = offset / bs
        let lead = Int(offset - skip * bs)
        let count = (Int64(lead) + length + bs - 1) / bs
        let cmd = "dd if=\(shq(remote)) bs=\(bs) skip=\(skip) count=\(count) 2>/dev/null"
        let r = try await Shell.run(path, ["-s", serial, "exec-out", cmd])
        guard r.out.count > lead else { throw ADBError.failed("Could not read file.") }
        return r.out.subdata(in: lead..<min(r.out.count, lead + Int(length)))
    }

    func push(_ serial: String, local: String, remote: String, box: ProcessBox? = nil) async throws {
        let r = try await Shell.run(path, ["-s", serial, "push", local, remote], box: box)
        if r.status != 0 {
            throw ADBError.failed(Self.cleanError(r))
        }
    }

    private static func cleanError(_ r: ProcResult) -> String {
        let msg = (r.stderr + "\n" + r.stdout)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.contains("error") || $0.contains("failed") } ?? r.stderr
        return msg.replacingOccurrences(of: "adb: error: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RemotePath {
    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
    static func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }
}

/// Produce "name (1).ext", "name (2).ext"… until `taken` doesn't contain it.
func uniqueName(_ name: String, taken: Set<String>) -> String {
    guard taken.contains(name) else { return name }
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var i = 1
    while true {
        let candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
        if !taken.contains(candidate) { return candidate }
        i += 1
    }
}

func uniqueLocalURL(in dir: URL, name: String) -> URL {
    let fm = FileManager.default
    let taken = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
    return dir.appendingPathComponent(uniqueName(name, taken: taken))
}

func localSize(_ url: URL) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue {
        return (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
    var total: Int64 = 0
    if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let f as URL in en {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
    return total
}
