import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let internalRoot = "/storage/emulated/0"

    // Connection
    @Published var adbPath: String?
    @Published var devices: [Device] = []
    @Published var selectedSerial: String? {
        didSet { if oldValue != selectedSerial { loadedSerial = nil } }
    }
    @Published var deviceName = ""
    @Published var storage: StorageInfo?
    @Published var locations: [Location] = []
    @Published var started = false

    // Browser
    @Published var currentPath = AppModel.internalRoot
    @Published var items: [RemoteFile] = []
    @Published var isLoading = false
    @Published var selection = Set<String>()
    @Published var sortOrder = [KeyPathComparator(\RemoteFile.name, comparator: .localizedStandard)]
    @Published var searchText = ""
    @Published var lastSync: Date?
    @Published var justChanged = false
    @Published var quickLookURL: URL?

    // UI prompts
    @Published var toast: Toast?
    @Published var renaming: RemoteFile?
    @Published var creatingFolder = false
    @Published var pendingDelete: [RemoteFile] = []
    @Published var clipboard: Clipboard?
    @Published var dropTargetPath: String?
    private var clipboardChangeCount = -1
    private var internalDrag: (paths: [String], at: Date)?

    // Settings
    private static let d = UserDefaults.standard
    @Published var showHidden = d.bool(forKey: "showHidden") {
        didSet { Self.d.set(showHidden, forKey: "showHidden"); Task { await reload() } }
    }
    @Published var viewMode = ViewMode(rawValue: d.string(forKey: "viewMode") ?? "") ?? .list {
        didSet { Self.d.set(viewMode.rawValue, forKey: "viewMode") }
    }
    @Published var customADBPath = d.string(forKey: "customADBPath") ?? "" {
        didSet { Self.d.set(customADBPath, forKey: "customADBPath") }
    }
    @Published var downloadFolderPath = d.string(forKey: "downloadFolder") ?? "" {
        didSet { Self.d.set(downloadFolderPath, forKey: "downloadFolder") }
    }
    @Published var revealAfterDownload = d.object(forKey: "revealAfterDownload") as? Bool ?? true {
        didSet { Self.d.set(revealAfterDownload, forKey: "revealAfterDownload") }
    }

    let transfers = TransferManager()
    let wireless = WirelessHub()
    enum Pane: String { case quickShare, wifi, transfers, guide }
    /// Page shown in the main area. nil = the phone browser (or USB setup when no phone).
    @Published var pane: Pane? = .guide   // open on the User Guide
    /// Selected rows on the Transfers page.
    @Published var transferSelection = Set<UUID>()

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var loadedSerial: String?
    private var fingerprint: String?
    private var lastFullRefresh = Date.distantPast
    private var loopsStarted = false

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    struct Clipboard {
        enum Mode { case cut, copy }
        let mode: Mode
        let paths: [String]
        let serial: String
    }

    var adb: ADB? { adbPath.map(ADB.init) }

    var selectedDevice: Device? { devices.first { $0.serial == selectedSerial } }

    var connection: ConnectionState {
        if !started { return .starting }
        guard adbPath != nil else { return .noADB }
        guard let d = selectedDevice else { return .noDevice }
        switch d.state {
        case "device": return .ready
        case "unauthorized": return .unauthorized
        default: return .offline
        }
    }

    var downloadFolder: URL {
        if !downloadFolderPath.isEmpty { return URL(fileURLWithPath: downloadFolderPath) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    var displayedItems: [RemoteFile] {
        var list = items
        if !showHidden { list = list.filter { !$0.isHidden } }
        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        let dirs = list.filter(\.isDir).sorted(using: sortOrder)
        let files = list.filter { !$0.isDir }.sorted(using: sortOrder)
        return dirs + files
    }

    var selectedFiles: [RemoteFile] { items.filter { selection.contains($0.id) } }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentPath != volumeRoot(for: currentPath) }

    // MARK: - Startup & polling

    func start() {
        wireless.attach(self)
        guard !loopsStarted else { return }
        loopsStarted = true
        Task {
            await locateADB()
            started = true
            await pollDevices()
            deviceLoop()
            folderLoop()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkForChanges(force: true) }
        }
    }

    func locateADB() async {
        adbPath = ADB.locate(custom: customADBPath.isEmpty ? nil : customADBPath)
        if let adb { await adb.startServer() }
    }

    private func deviceLoop() {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if adbPath == nil { await locateADB(); continue }
                await pollDevices()
            }
        }
    }

    private func folderLoop() {
        Task {
            while true {
                let active = NSApp.isActive
                try? await Task.sleep(nanoseconds: active ? 1_200_000_000 : 4_000_000_000)
                await checkForChanges(force: false)
            }
        }
    }

    func pollDevices() async {
        guard let adb else { return }
        guard let list = try? await adb.devices() else { return }
        if list != devices { devices = list }

        if selectedSerial == nil || !list.contains(where: { $0.serial == selectedSerial }) {
            selectedSerial = (list.first { $0.state == "device" } ?? list.first)?.serial
        }
        if connection == .ready, let serial = selectedSerial, loadedSerial != serial {
            loadedSerial = serial
            await deviceBecameReady(serial)
        } else if connection != .ready {
            loadedSerial = nil
            if !items.isEmpty { items = []; selection = [] }
        }
    }

    private func deviceBecameReady(_ serial: String) async {
        guard let adb else { return }
        deviceName = await adb.deviceName(serial) ?? selectedDevice?.model ?? "Android Phone"
        backStack = []; forwardStack = []
        currentPath = Self.internalRoot
        await reload()
        await refreshSidebar()
    }

    func refreshSidebar() async {
        guard let adb, let serial = selectedSerial else { return }
        storage = await adb.storage(serial, path: Self.internalRoot)
        let candidates: [(String, String, String)] = [
            ("Camera", "DCIM/Camera", "camera"),
            ("Screenshots", "DCIM/Screenshots", "camera.viewfinder"),
            ("Screenshots", "Pictures/Screenshots", "camera.viewfinder"),
            ("Pictures", "Pictures", "photo.on.rectangle"),
            ("Movies", "Movies", "film"),
            ("Downloads", "Download", "arrow.down.circle"),
            ("Documents", "Documents", "doc.text"),
            ("Music", "Music", "music.note"),
            ("Telegram", "Android/media/org.telegram.messenger/Telegram", "paperplane"),
            ("Telegram", "Telegram", "paperplane"),
            ("WhatsApp", "Android/media/com.whatsapp/WhatsApp/Media", "message"),
        ]
        let existing = await adb.existingDirs(serial, root: Self.internalRoot, candidates: candidates.map { $0.1 })
        var locs = [Location(title: "Internal Storage", path: Self.internalRoot, symbol: "internaldrive")]
        var seenTitles = Set<String>()
        for (title, rel, sym) in candidates where existing.contains(rel) && !seenTitles.contains(title) {
            seenTitles.insert(title)
            locs.append(Location(title: title, path: RemotePath.join(Self.internalRoot, rel), symbol: sym))
        }
        for (i, vol) in await adb.externalVolumes(serial).enumerated() {
            locs.append(Location(title: i == 0 ? "SD Card" : "SD Card \(i + 1)", path: vol, symbol: "sdcard"))
        }
        if locs != locations { locations = locs }
    }

    /// Live sync: cheaply checks the folder's fingerprint and reloads if anything changed on the phone.
    func checkForChanges(force: Bool) async {
        guard connection == .ready, !isLoading, let adb, let serial = selectedSerial else { return }
        let path = currentPath
        let due = Date().timeIntervalSince(lastFullRefresh) > 8
        if !force && !due {
            let fp = await adb.dirFingerprint(serial, dir: path)
            guard path == currentPath, fp != fingerprint else { return }
        }
        await reload(silent: true)
    }

    // MARK: - Loading

    func reload(silent: Bool = false) async {
        guard let adb, let serial = selectedSerial, connection == .ready else { return }
        let path = currentPath
        if !silent { isLoading = true }
        defer { if !silent { isLoading = false } }
        let fp = await adb.dirFingerprint(serial, dir: path)
        do {
            let list = try await adb.list(serial, dir: path, showHidden: showHidden)
            guard path == currentPath else { return }
            fingerprint = fp
            lastFullRefresh = Date()
            lastSync = Date()
            if list.map(\.signature) != items.map(\.signature) {
                let changedExternally = silent && !items.isEmpty
                withAnimation(.easeInOut(duration: 0.2)) { items = list }
                let ids = Set(list.map(\.id))
                selection = selection.filter { ids.contains($0) }
                if changedExternally { flashChanged() }
            }
        } catch ADBError.folderMissing {
            guard path == currentPath else { return }
            // Folder was renamed / moved / deleted on the phone: walk up to something that exists.
            var p = RemotePath.parent(path)
            while p.count > 1, !(await adb.exists(serial, p)) { p = RemotePath.parent(p) }
            if p.count <= 1 { p = Self.internalRoot }
            showToast("“\(RemotePath.name(path))” was moved or deleted on the phone.", error: true)
            await navigate(to: p, record: false)
        } catch {
            guard path == currentPath else { return }
            if !silent { showToast(error.localizedDescription, error: true) }
            if case ADBError.permissionDenied = error, canGoBack { goBack() }
        }
    }

    private func flashChanged() {
        justChanged = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            justChanged = false
        }
    }

    // MARK: - Navigation

    func navigate(to path: String, record: Bool = true) async {
        guard path != currentPath else { await reload(); return }
        if record { backStack.append(currentPath); forwardStack.removeAll() }
        currentPath = path
        items = []
        selection = []
        searchText = ""
        fingerprint = nil
        await reload()
    }

    func go(_ path: String) {
        pane = nil
        Task { await navigate(to: path) }
    }

    func goBack() {
        pane = nil
        guard let p = backStack.popLast() else { return }
        forwardStack.append(currentPath)
        Task { await navigate(to: p, record: false) }
    }

    func goForward() {
        pane = nil
        guard let p = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        Task { await navigate(to: p, record: false) }
    }

    func goUp() {
        guard canGoUp else { return }
        go(RemotePath.parent(currentPath))
    }

    func volumeRoot(for path: String) -> String {
        if path.hasPrefix(Self.internalRoot) { return Self.internalRoot }
        if let loc = locations.first(where: { $0.symbol == "sdcard" && path.hasPrefix($0.path) }) { return loc.path }
        return "/"
    }

    /// Breadcrumb components: (title, path)
    var breadcrumbs: [(String, String)] {
        let root = volumeRoot(for: currentPath)
        let rootTitle = locations.first { $0.path == root }?.title ?? (root == Self.internalRoot ? "Internal Storage" : root)
        var crumbs = [(rootTitle, root)]
        let rest = currentPath.dropFirst(root.count).split(separator: "/")
        var p = root
        for c in rest {
            p = RemotePath.join(p, String(c))
            crumbs.append((String(c), p))
        }
        return crumbs
    }

    // MARK: - Actions

    func open(_ ids: Set<String>) {
        let files = items.filter { ids.contains($0.id) }
        if files.count == 1, let f = files.first, f.isDir {
            go(f.path); return
        }
        for f in files where !f.isDir { fetchToCache(f) { url in NSWorkspace.shared.open(url) } }
    }

    func quickLook() {
        guard let f = selectedFiles.first, !f.isDir else { return }
        if quickLookURL != nil { quickLookURL = nil; return }
        fetchToCache(f) { [weak self] url in self?.quickLookURL = url }
    }

    private func fetchToCache(_ f: RemoteFile, then: @escaping @MainActor (URL) -> Void) {
        guard let adb, let serial = selectedSerial else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidShare/Open/\(abs(f.signature.hashValue))", isDirectory: true)
        let dest = dir.appendingPathComponent(f.name)
        if FileManager.default.fileExists(atPath: dest.path), localSize(dest) == f.size {
            then(dest); return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t = Transfer(kind: .open, name: f.name, detail: "Preparing preview",
                         total: { f.size },
                         probe: { localSize(dest) },
                         work: { box in try await adb.pull(serial, remote: f.path, local: dest.path, box: box) },
                         completion: { t in if t.state == .done { then(dest) } })
        transfers.enqueue(t)
    }

    func download(_ files: [RemoteFile], to folder: URL? = nil) {
        guard let adb, let serial = selectedSerial, !files.isEmpty else { return }
        let target = folder ?? downloadFolder
        var reserved = Set<String>()
        for f in files {
            let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []).union(reserved)
            let name = uniqueName(f.name, taken: taken)
            reserved.insert(name)
            let dest = target.appendingPathComponent(name)
            let t = Transfer(kind: .download, name: f.name, detail: "to \(target.lastPathComponent)",
                             total: { f.isDir ? await adb.remoteSize(serial, f.path, isDir: true) : f.size },
                             probe: { localSize(dest) },
                             work: { box in try await adb.pull(serial, remote: f.path, local: dest.path, box: box) },
                             completion: { [weak self] t in
                                 t.resultURL = dest
                                 if t.state == .done, self?.revealAfterDownload == true,
                                    self?.transfers.pendingCount == 0 {
                                     NSWorkspace.shared.activateFileViewerSelecting([dest])
                                 }
                             })
            transfers.enqueue(t)
        }
    }

    func downloadWithPicker(_ files: [RemoteFile]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose where to save \(files.count == 1 ? "“\(files[0].name)”" : "\(files.count) items") on your Mac"
        panel.directoryURL = downloadFolder
        if panel.runModal() == .OK, let url = panel.url { download(files, to: url) }
    }

    func upload(_ urls: [URL], to remoteDir: String? = nil) {
        guard let adb, let serial = selectedSerial, !urls.isEmpty else { return }
        let dir = remoteDir ?? currentPath
        Task {
            let existing = (try? await adb.list(serial, dir: dir, showHidden: true)) ?? []
            var taken = Set(existing.map(\.name))
            for url in urls {
                let name = uniqueName(url.lastPathComponent, taken: taken)
                taken.insert(name)
                let remote = RemotePath.join(dir, name)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                let dirFlag = isDir.boolValue
                let t = Transfer(kind: .upload, name: url.lastPathComponent, detail: "to \(RemotePath.name(dir))",
                                 total: { localSize(url) },
                                 probe: { await adb.remoteSize(serial, remote, isDir: dirFlag) },
                                 work: { box in
                                     try await adb.push(serial, local: url.path, remote: remote, box: box)
                                     await adb.mediaScan(serial, [remote])
                                 },
                                 completion: { [weak self] t in
                                     if t.state == .cancelled { Task { try? await adb.delete(serial, [remote]) } }
                                     Task { await self?.reload(silent: true) }
                                 })
                transfers.enqueue(t)
            }
        }
    }

    func uploadWithPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Copy to Phone"
        panel.message = "Choose files or folders to copy into “\(RemotePath.name(currentPath))” on your phone"
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    func handleDrop(_ providers: [NSItemProvider], to remoteDir: String? = nil) -> Bool {
        dropTargetPath = nil
        // A drag that started inside this window (phone → phone folder) = move.
        // Drags from Finder start while Finder is the active app, so this can't misfire on them.
        if let drag = internalDrag, NSApp.isActive, Date().timeIntervalSince(drag.at) < 300 {
            internalDrag = nil
            let target = remoteDir ?? currentPath
            let paths = drag.paths.filter { RemotePath.parent($0) != target && $0 != target }
            guard !paths.isEmpty else { return false }
            transferOnPhone(paths, mode: .cut, into: target)
            return true
        }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for p in fileProviders {
                if let url = await Self.loadURL(p) { urls.append(url) }
            }
            upload(urls, to: remoteDir)
        }
        return true
    }

    private static func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = p.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }

    func createFolder(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let adb, let serial = selectedSerial, !clean.isEmpty else { return }
        guard !clean.contains("/") else { showToast("Folder names can't contain “/”.", error: true); return }
        let path = RemotePath.join(currentPath, clean)
        Task {
            do {
                if await adb.exists(serial, path) { throw ADBError.failed("“\(clean)” already exists.") }
                try await adb.mkdir(serial, path)
                await reload(silent: true)
                selection = [path]
            } catch { showToast(error.localizedDescription, error: true) }
        }
    }

    func rename(_ f: RemoteFile, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let adb, let serial = selectedSerial, !clean.isEmpty, clean != f.name else { return }
        guard !clean.contains("/") else { showToast("Names can't contain “/”.", error: true); return }
        let dest = RemotePath.join(RemotePath.parent(f.path), clean)
        Task {
            do {
                if await adb.exists(serial, dest) { throw ADBError.failed("“\(clean)” already exists.") }
                try await adb.move(serial, from: f.path, to: dest)
                await reload(silent: true)
                selection = [dest]
                Task.detached { await adb.mediaScan(serial, [f.path, dest]) }
            } catch { showToast(error.localizedDescription, error: true) }
        }
    }

    func delete(_ files: [RemoteFile]) {
        guard let adb, let serial = selectedSerial, !files.isEmpty else { return }
        let paths = files.map(\.path)
        Task {
            do {
                try await adb.delete(serial, paths)
                await reload(silent: true)
                showToast(files.count == 1 ? "Deleted “\(files[0].name)”" : "Deleted \(files.count) items")
                Task.detached { await adb.mediaScan(serial, paths) }
            } catch { showToast(error.localizedDescription, error: true) }
        }
    }

    func setClipboard(_ mode: Clipboard.Mode, _ files: [RemoteFile]) {
        guard let serial = selectedSerial, !files.isEmpty else { return }
        clipboard = Clipboard(mode: mode, paths: files.map(\.path), serial: serial)
        // Mark the system pasteboard so a later Finder copy takes priority over this one.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(files.map(\.name).joined(separator: "\n"), forType: .string)
        clipboardChangeCount = pb.changeCount
        let verb = mode == .cut ? "Cut" : "Copied"
        showToast("\(verb) \(files.count == 1 ? "“\(files[0].name)”" : "\(files.count) items") — select or open a folder, then press ⌘V")
    }

    /// Where ⌘V goes: the selected folder if exactly one folder is selected, otherwise the open folder.
    var pasteTarget: String {
        let sel = selectedFiles
        if sel.count == 1, sel[0].isDir, !(clipboard?.paths.contains(sel[0].path) ?? false) { return sel[0].path }
        return currentPath
    }

    func paste(into dir: String? = nil) {
        guard let clip = clipboard, clip.serial == selectedSerial else { return }
        transferOnPhone(clip.paths, mode: clip.mode, into: dir ?? pasteTarget)
        if clip.mode == .cut { clipboard = nil }
    }

    /// Move or copy items between folders on the phone.
    func transferOnPhone(_ paths: [String], mode: Clipboard.Mode, into target: String) {
        guard let adb, let serial = selectedSerial, !paths.isEmpty else { return }
        let targetName = target == Self.internalRoot ? "Internal Storage" : RemotePath.name(target)
        Task {
            let existing = (try? await adb.list(serial, dir: target, showHidden: true)) ?? []
            var taken = Set(existing.map(\.name))
            var moved: [String] = []
            var count = 0
            do {
                for src in paths {
                    if mode == .cut && RemotePath.parent(src) == target { continue }
                    if target == src || target.hasPrefix(src + "/") {
                        throw ADBError.failed("Can't put “\(RemotePath.name(src))” inside itself.")
                    }
                    let name = uniqueName(RemotePath.name(src), taken: taken)
                    taken.insert(name)
                    let dest = RemotePath.join(target, name)
                    count += 1
                    if mode == .cut {
                        try await adb.move(serial, from: src, to: dest)
                        moved += [src, dest]
                    } else {
                        let t = Transfer(kind: .phoneCopy, name: name, detail: "in \(targetName)",
                                         total: { 0 }, probe: { 0 },
                                         work: { _ in
                                             try await adb.copy(serial, from: src, to: dest)
                                             await adb.mediaScan(serial, [dest])
                                         },
                                         completion: { [weak self] _ in Task { await self?.reload(silent: true) } })
                        transfers.enqueue(t)
                    }
                }
                await reload(silent: true)
                if count == 0 {
                    showToast("Already in “\(targetName)”. Select a different folder and press ⌘V.", error: true)
                } else if mode == .cut {
                    showToast("Moved \(count == 1 ? "“\(RemotePath.name(paths[0]))”" : "\(count) items") to “\(targetName)”")
                } else {
                    showToast("Copying \(count) item\(count == 1 ? "" : "s") to “\(targetName)”…")
                }
                if !moved.isEmpty { Task.detached { await adb.mediaScan(serial, moved) } }
            } catch { showToast(error.localizedDescription, error: true) }
        }
    }

    // MARK: - Edit menu (⌘X / ⌘C / ⌘V / ⌘A) — works whether or not the list has focus

    private var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSText }

    // MARK: Transfers page: copy out, paste/drop in, trash

    /// Finished files (that still exist) for the given transfer rows.
    func transferFiles(_ ids: Set<UUID>) -> [URL] {
        transfers.items.compactMap { t in
            guard ids.contains(t.id), t.state == .done, let u = t.resultURL,
                  FileManager.default.fileExists(atPath: u.path) else { return nil }
            return u
        }
    }

    func copyTransferFiles(_ ids: Set<UUID>) {
        let urls = transferFiles(ids)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        showToast(urls.count == 1 ? "Copied “\(urls[0].lastPathComponent)”" : "Copied \(urls.count) files")
    }

    func trashTransferFiles(_ ids: Set<UUID>) {
        let urls = transferFiles(ids)
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.showToast("Couldn't move to Trash: \(error.localizedDescription)", error: true); return }
                for t in self.transfers.items where ids.contains(t.id) { self.transfers.remove(t) }
                self.transferSelection.subtract(ids)
                self.showToast(urls.count == 1 ? "Moved “\(urls[0].lastPathComponent)” to Trash" : "Moved \(urls.count) files to Trash")
            }
        }
    }

    /// Files dropped or pasted on the Transfers page → phone (USB if plugged in, otherwise Wi-Fi).
    func sendToPhone(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if connection == .ready {
            upload(urls, to: pasteTarget)
        } else if wireless.enabled {
            wireless.addToOutbox(urls)
            showToast("Ready on the phone's Android Share page under “From Mac”")
        } else {
            showToast("Plug in the phone or turn on Wi-Fi Transfer to send files", error: true)
        }
    }

    func menuCut() {
        if isEditingText { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil); return }
        if pane == .transfers { copyTransferFiles(transferSelection); return }
        setClipboard(.cut, selectedFiles)
    }

    func menuCopy() {
        if isEditingText { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil); return }
        if pane == .transfers { copyTransferFiles(transferSelection); return }
        setClipboard(.copy, selectedFiles)
    }

    func menuPaste() {
        if isEditingText { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil); return }
        if pane == .transfers {
            let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            sendToPhone(urls)
            return
        }
        guard connection == .ready else { return }
        let pb = NSPasteboard.general
        if clipboard != nil, pb.changeCount == clipboardChangeCount { paste(); return }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            upload(urls, to: pasteTarget)       // files copied in Finder → phone
            return
        }
        if clipboard != nil { paste() }
    }

    func menuSelectAll() {
        if isEditingText { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil); return }
        if pane == .transfers { transferSelection = Set(transfers.items.map(\.id)); return }
        selection = Set(displayedItems.map(\.id))
    }

    /// Sub-folders of the open folder, for the "Move to" menu.
    var foldersHere: [RemoteFile] { displayedItems.filter(\.isDir) }

    func refresh() {
        Task {
            await reload()
            await refreshSidebar()
        }
    }

    func showToast(_ message: String, error: Bool = false) {
        let t = Toast(message: message, isError: error)
        withAnimation { toast = t }
        Task {
            try? await Task.sleep(nanoseconds: error ? 4_500_000_000 : 3_000_000_000)
            if toast?.id == t.id { withAnimation { toast = nil } }
        }
    }

    // MARK: - Drag out to Finder

    func dragProvider(for f: RemoteFile) -> NSItemProvider {
        let paths = selection.contains(f.id) ? Array(selection) : [f.path]
        internalDrag = (paths, Date())
        let provider = NSItemProvider()
        provider.suggestedName = f.name
        guard let adb, let serial = selectedSerial else { return provider }
        let type: UTType = f.isDir ? .folder : (UTType(filenameExtension: f.ext) ?? .data)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            let progress = Progress(totalUnitCount: 100)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("AndroidShare/Drag/\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(f.name)
            Task.detached {
                do {
                    try await adb.pull(serial, remote: f.path, local: dest.path)
                    progress.completedUnitCount = 100
                    done(dest, false, nil)
                } catch {
                    done(nil, false, error)
                }
            }
            return progress
        }
        // Also offer the phone path as text, so dropping into Terminal / a text field types the path
        // (escaped like Finder does: spaces etc. get a backslash).
        provider.registerObject(Self.shellEscaped(f.path) as NSString, visibility: .all)
        return provider
    }

    static func shellEscaped(_ path: String) -> String {
        let special = Set(" !\"#$&'()*,;<>?[\\]^`{|}~")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    /// Copies the phone path(s) of the given items, ready to paste into Terminal (e.g. for adb).
    func copyPaths(_ files: [RemoteFile]) {
        let text = files.map { Self.shellEscaped($0.path) }.joined(separator: " ")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        showToast(files.count == 1 ? "Copied path of “\(files[0].name)”" : "Copied \(files.count) paths")
    }
}
