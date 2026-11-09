import SwiftUI
import UniformTypeIdentifiers

struct WirelessView: View {
    enum Tab { case quickShare, wifi }
    let tab: Tab

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wireless: WirelessHub
    @State private var dropping = false
    @State private var copied = false
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch tab {
                case .quickShare:
                    pageHeader(symbol: "square.and.arrow.down.on.square", title: "Quick Share",
                               text: "Your Mac appears in Android's built-in Quick Share, like AirDrop. Works on Samsung, Pixel, Motorola, OnePlus and other phones with Google services, and with Quick Share apps such as Bada.",
                               isOn: $wireless.quickShareEnabled)
                    if wireless.quickShareEnabled { quickShareOn } else { quickShareOff }
                case .wifi:
                    pageHeader(symbol: "wifi", title: "Wi-Fi Transfer",
                               text: "Works on every phone, including Xiaomi, Huawei, OPPO and vivo. The phone uses its web browser, so nothing needs installing.",
                               isOn: $wireless.enabled)
                    if wireless.enabled {
                        pairingCard
                        sendToPhoneCard
                        footer
                    } else {
                        offCard
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(tab == .quickShare ? "Quick Share" : "Wi-Fi Transfer")
        .confirmationDialog("Unpair all phones?", isPresented: $confirmReset) {
            Button("Unpair All", role: .destructive) { wireless.resetPairing() }
        } message: {
            Text("Phones that scanned the old QR code won't be able to send or receive anymore until they scan the new one.")
        }
    }

    // MARK: Sections

    private func pageHeader(symbol: String, title: String, text: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .secondary)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title.bold())
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.large)
        }
    }

    private var quickShareOn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(qsColor).frame(width: 9, height: 9)
                Text(qsText).font(.headline)
            }
            StepRow(n: 1, text: "On the phone, open a photo or file and tap **Share → Quick Share**.")
            StepRow(n: 2, text: "Pick **\(wireless.macName)**.")
            StepRow(n: 3, text: "Check that the PIN on the Mac matches the phone, then click **Accept**. Files are saved to **\(model.downloadFolder.lastPathComponent)**.")
            Divider()
            Toggle("Accept automatically, without asking", isOn: $wireless.quickShareAutoAccept)
            Text("The phone and Mac must be on the same Wi-Fi. If the Mac doesn't appear, set Quick Share visibility on the phone to **Everyone**. Links open in your browser, and text is copied to the clipboard.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var quickShareOff: some View {
        StepCard {
            Text("Send from Android like AirDrop").font(.headline)
            StepRow(n: 1, text: "Turn on Quick Share. This Mac becomes visible to phones on the same Wi-Fi.")
            StepRow(n: 2, text: "On the phone, tap **Share → Quick Share** and pick this Mac.")
            StepRow(n: 3, text: "Accept on the Mac. Done.")
            Button("Turn On Quick Share") { wireless.quickShareEnabled = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            Text("Phones without Google services (most Chinese ROMs) don't have Quick Share. Use **Wi-Fi Transfer** for those.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var qsText: String {
        switch wireless.quickShareStatus {
        case .ready: return "Visible to nearby Android phones"
        case .starting: return "Starting…"
        case .failed(let m): return "Couldn't start: \(m)"
        default: return "Off"
        }
    }

    private var qsColor: Color {
        switch wireless.quickShareStatus {
        case .ready: return .green
        case .starting: return .orange
        default: return .red
        }
    }

    private var offCard: some View {
        StepCard {
            Text("How it works").font(.headline)
            StepRow(n: 1, text: "Turn on Wi-Fi Transfer. Your Mac shows a QR code.")
            StepRow(n: 2, text: "Scan it with your phone's **camera**. A Android Share page opens in the browser.")
            StepRow(n: 3, text: "Tap **Send photos & files to Mac**. They're saved in your **\(model.downloadFolder.lastPathComponent)** folder.")
            StepRow(n: 4, text: "In the browser menu, tap **Add to Home screen**. Next time, just tap the icon. No more scanning.")
            Button("Turn On Wi-Fi Transfer") { wireless.enabled = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            Text("Android Share keeps running in the menu bar while this is on, so your phone can send files anytime the Mac is awake.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var pairingCard: some View {
        HStack(alignment: .top, spacing: 24) {
            qrBox
            VStack(alignment: .leading, spacing: 12) {
                statusLine
                StepRow(n: 1, text: "Open the **camera** on your phone and point it at the code.")
                StepRow(n: 2, text: "Tap the link that appears. The Android Share page opens.")
                StepRow(n: 3, text: "Tap **Send photos & files to Mac**.")
                StepRow(n: 4, text: "Browser menu → **Add to Home screen**, so next time it's one tap.")
                Text("Scanning is only needed once per phone. If the Mac joins a different Wi-Fi network, scan again.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var qrBox: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.white)
                if let img = wireless.qrImage, wireless.status == .ready {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                } else {
                    VStack(spacing: 8) {
                        if wireless.status == .starting { ProgressView() }
                        else { Image(systemName: "wifi.slash").font(.largeTitle).foregroundStyle(.gray) }
                    }
                }
            }
            .frame(width: 210, height: 210)
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)

            if let addr = wireless.pageAddress {
                HStack(spacing: 6) {
                    Text(addr.replacingOccurrences(of: "http://", with: ""))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(wireless.pairingURL ?? addr, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy pairing link")
                }
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.headline)
        }
    }

    private var sendToPhoneCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Send to Phone").font(.headline)
                Spacer()
                if !wireless.outbox.isEmpty {
                    Button("Clear") { wireless.clearOutbox() }.buttonStyle(.borderless)
                }
                Button("Add Files…") { pickFiles() }
            }
            Text("Files you add here show up under **From Mac** on the phone's Android Share page, ready to download.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(spacing: 0) {
                if wireless.outbox.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc").font(.title2)
                        Text("Drop files here")
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    ForEach(wireless.outbox) { item in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                .resizable().frame(width: 22, height: 22)
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.size.byteString).foregroundStyle(.secondary).font(.callout)
                            Button { wireless.removeFromOutbox(item) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Stop offering this file")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        if item.id != wireless.outbox.last?.id { Divider() }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(dropping ? Color.accentColor : Color.secondary.opacity(0.35),
                                  style: StrokeStyle(lineWidth: dropping ? 2 : 1, dash: wireless.outbox.isEmpty ? [5] : []))
            )
            .background(dropping ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                loadURLs(providers)
                return true
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                NSWorkspace.shared.open(model.downloadFolder)
            } label: {
                Label("Received files go to “\(model.downloadFolder.lastPathComponent)”", systemImage: "folder")
            }
            .buttonStyle(.link)
            Spacer()
            Button("Unpair All Phones…") { confirmReset = true }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: Status

    private var statusText: String {
        switch wireless.status {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .noNetwork: return "Connect this Mac to Wi-Fi"
        case .failed(let m): return "Couldn't start: \(m)"
        case .ready:
            if let seen = wireless.lastPhoneSeen, Date().timeIntervalSince(seen) < 15 {
                return "Phone connected"
            }
            return "Ready. Waiting for your phone"
        }
    }

    private var statusColor: Color {
        switch wireless.status {
        case .ready: return .green
        case .starting: return .orange
        default: return .red
        }
    }

    // MARK: Files

    private func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.canChooseFiles = true
        if p.runModal() == .OK { wireless.addToOutbox(p.urls) }
    }

    private func loadURLs(_ providers: [NSItemProvider]) {
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { wireless.addToOutbox([url]) }
            }
        }
    }
}

/// Menu-bar item shown while Wi-Fi Transfer is on, so the app can keep receiving with no window open.
struct WirelessMenu: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wireless: WirelessHub
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if wireless.quickShareEnabled {
            Text(wireless.quickShareStatus == .ready ? "Quick Share: visible as \(wireless.macName)" : "Quick Share: starting…")
        }
        if wireless.enabled {
            Text(wireless.status == .ready ? "Wi-Fi Transfer is on" : "Wi-Fi Transfer: not ready")
            if let addr = wireless.pageAddress {
                Text(addr.replacingOccurrences(of: "http://", with: ""))
            }
        }
        Divider()
        Button("Show QR Code…") {
            model.pane = .wifi
            showMainWindow()
        }
        Button("Open Received Files") { NSWorkspace.shared.open(model.downloadFolder) }
        Divider()
        Button("Turn Off Wireless") {
            wireless.enabled = false
            wireless.quickShareEnabled = false
        }
        Button("Quit Android Share") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && ($0.isVisible || $0.isMiniaturized) }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
