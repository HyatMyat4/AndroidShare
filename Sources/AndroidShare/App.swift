import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        // Always start with a fresh main window. Without this, macOS can restore a
        // "no windows open" state (e.g. after running in the menu bar) and the app looks dead.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true   // Dock click with no window open → SwiftUI opens a new main window
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Use the bundled icon for the Dock tile directly, so a stale Dock icon cache can't show an old one.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running (menu bar) while Wi-Fi Transfer is on, so the phone can still send files.
        !UserDefaults.standard.bool(forKey: "wifiEnabled") && !UserDefaults.standard.bool(forKey: "quickShareEnabled")
    }
}

@main
struct AndroidShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AppModel
    @StateObject private var wireless: WirelessHub

    init() {
        Self.migrateOldSettings()
        let m = AppModel()
        _model = StateObject(wrappedValue: m)
        _wireless = StateObject(wrappedValue: m.wireless)
    }

    /// The app used to be called DroidBridge (bundle id com.htetmyat.droidbridge).
    /// Copy its settings once so the Wi-Fi pairing key, toggles and save folder survive the rename.
    private static func migrateOldSettings() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromDroidBridge"),
              let old = UserDefaults(suiteName: "com.htetmyat.droidbridge") else { return }
        let keys = ["wifiEnabled", "wifiKey", "wifiPort", "quickShareEnabled", "quickShareAutoAccept",
                    "showHidden", "viewMode", "customADBPath", "downloadFolder", "revealAfterDownload", "guideExpanded"]
        for k in keys where d.object(forKey: k) == nil {
            if let v = old.object(forKey: k) { d.set(v, forKey: k) }
        }
        d.set(true, forKey: "migratedFromDroidBridge")
    }

    var body: some Scene {
        WindowGroup("Android Share", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.transfers)
                .environmentObject(wireless)
                .frame(minWidth: 860, minHeight: 540)
                .onAppear { model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Folder on Phone") { model.creatingFolder = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.connection != .ready)
                Button("Copy Files to Phone…") { model.uploadWithPicker() }
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(model.connection != .ready)
                Button("Copy Selection to Mac") { model.download(model.selectedFiles) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.selection.isEmpty)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { model.menuCut() }.keyboardShortcut("x", modifiers: .command)
                Button("Copy") { model.menuCopy() }.keyboardShortcut("c", modifiers: .command)
                Button("Paste") { model.menuPaste() }.keyboardShortcut("v", modifiers: .command)
                Button("Select All") { model.menuSelectAll() }.keyboardShortcut("a", modifiers: .command)
            }
            CommandMenu("Go") {
                Button("Back") { model.goBack() }.keyboardShortcut("[", modifiers: .command)
                Button("Forward") { model.goForward() }.keyboardShortcut("]", modifiers: .command)
                Button("Enclosing Folder") { model.goUp() }.keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button("Refresh") { model.refresh() }.keyboardShortcut("r", modifiers: .command)
                Divider()
                ForEach(model.locations) { loc in
                    Button(loc.title) { model.go(loc.path) }
                }
            }
        }

        MenuBarExtra(isInserted: Binding(
            get: { wireless.enabled || wireless.quickShareEnabled },
            // The menu bar icon only follows the switches. SwiftUI may report "not inserted"
            // while it is still adding the icon; writing that back would turn the features off.
            set: { _ in }
        )) {
            WirelessMenu()
                .environmentObject(model)
                .environmentObject(wireless)
        } label: {
            Image(systemName: "wifi")
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
