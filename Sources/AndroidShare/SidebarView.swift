import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wireless: WirelessHub
    @EnvironmentObject var transfers: TransferManager
    @State private var dropTarget: String?

    private static let usbTag = "pane:usb"

    private var selectionBinding: Binding<String?> {
        Binding(
            get: {
                if let pane = model.pane { return "pane:" + pane.rawValue }
                if model.connection != .ready { return Self.usbTag }
                return model.locations.first { $0.path == model.currentPath }?.path
            },
            set: {
                guard let p = $0 else { return }
                if p.hasPrefix("pane:") {
                    model.pane = AppModel.Pane(rawValue: String(p.dropFirst("pane:".count)))
                } else {
                    model.go(p)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            DeviceHeader()
            List(selection: selectionBinding) {
                if model.connection == .ready {
                    Section("Phone") {
                        ForEach(model.locations) { loc in
                            Label(loc.title, systemImage: loc.symbol)
                                .tag(loc.path)
                                .listRowBackground(dropTarget == loc.path ? Color.accentColor.opacity(0.25) : nil)
                                .onDrop(of: [.fileURL, .item], isTargeted: Binding(
                                    get: { dropTarget == loc.path },
                                    set: { dropTarget = $0 ? loc.path : (dropTarget == loc.path ? nil : dropTarget) }
                                )) { providers in
                                    model.handleDrop(providers, to: loc.path)
                                }
                        }
                    }
                }
                Section("Share") {
                    HStack {
                        Label("Quick Share", systemImage: "square.and.arrow.down.on.square")
                        Spacer()
                        if wireless.quickShareEnabled { statusDot(wireless.quickShareStatus) }
                    }
                    .tag("pane:quickShare")
                    HStack {
                        Label("Wi-Fi Transfer", systemImage: "wifi")
                        Spacer()
                        if wireless.enabled { statusDot(wireless.status) }
                    }
                    .tag("pane:wifi")
                    if model.connection != .ready {
                        Label("USB Cable", systemImage: "cable.connector").tag(Self.usbTag)
                    }
                    HStack {
                        Label("Transfers", systemImage: "doc.on.doc")
                        Spacer()
                        if transfers.pendingCount > 0 {
                            Text("\(transfers.pendingCount)")
                                .font(.caption2.bold()).monospacedDigit()
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor))
                                .foregroundStyle(.white)
                        }
                    }
                    .tag("pane:transfers")
                    Label("User Guide", systemImage: "lightbulb")
                        .tag("pane:guide")
                }
                Section("Mac") {
                    Button {
                        NSWorkspace.shared.open(model.downloadFolder)
                    } label: {
                        Label("Saved to: \(model.downloadFolder.lastPathComponent)", systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)

        }
    }
}

private func statusDot(_ s: WirelessHub.Status) -> some View {
    Circle().fill(s == .ready ? Color.green : Color.orange).frame(width: 7, height: 7)
}

struct DeviceHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "smartphone")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(model.connection == .ready ? Color.accentColor : .secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if model.devices.count > 1 {
                Picker("Device", selection: $model.selectedSerial) {
                    ForEach(model.devices) { d in
                        Text("\(d.model) (\(d.state))").tag(Optional(d.serial))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            if model.connection == .ready, let s = model.storage {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: s.fraction)
                        .tint(s.fraction > 0.9 ? .red : .accentColor)
                    Text("\(s.free.byteString) free of \(s.total.byteString)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var title: String {
        model.connection == .ready ? model.deviceName : (model.selectedDevice?.model ?? "No Phone")
    }

    private var statusText: String {
        switch model.connection {
        case .ready: return "Connected via USB"
        case .unauthorized: return "Waiting for “Allow” on phone"
        case .offline: return "Phone offline"
        case .noDevice: return "Not connected"
        case .noADB: return "Setup needed"
        case .starting: return "Starting…"
        }
    }

    private var statusColor: Color {
        switch model.connection {
        case .ready: return .green
        case .unauthorized, .offline, .starting: return .orange
        default: return .secondary
        }
    }
}
