import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct TransfersView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var transfers: TransferManager
    @State private var previewURL: URL?
    @State private var dropping = false
    @State private var confirmTrash: Set<UUID>?

    private var active: [Transfer] { transfers.items.filter { !$0.isFinished }.reversed() }
    private var finished: [Transfer] { transfers.items.filter(\.isFinished).reversed() }

    var body: some View {
        Group {
            if transfers.items.isEmpty {
                ContentUnavailableView {
                    Label("No Transfers Yet", systemImage: "doc.on.doc")
                } description: {
                    Text("Files you move over USB, Quick Share or Wi-Fi show up here.\nDrop files here to send them to your phone.")
                }
            } else {
                List(selection: $model.transferSelection) {
                    if !active.isEmpty {
                        Section("In Progress") {
                            ForEach(active) { row($0) }
                        }
                    }
                    if !finished.isEmpty {
                        Section("Recent") {
                            ForEach(finished) { row($0) }
                        }
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand { askTrash(model.transferSelection) }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    let files = model.transferFiles(ids)
                    if !files.isEmpty {
                        Button("Open") { files.forEach { NSWorkspace.shared.open($0) } }
                        Button("Quick Look") { previewURL = files.first }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
                        Divider()
                        Button("Copy") { model.copyTransferFiles(ids) }
                        Divider()
                        Button("Move to Trash") { askTrash(ids) }
                    }
                    Button("Remove from List") {
                        for t in transfers.items where ids.contains(t.id) { transfers.remove(t) }
                    }
                    .disabled(!transfers.items.contains { ids.contains($0.id) && $0.isFinished })
                } primaryAction: { ids in
                    model.transferFiles(ids).forEach { NSWorkspace.shared.open($0) }
                }
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(Label("Drop to send to phone", systemImage: "arrow.up.circle.fill")
                        .font(.title3.bold()).padding(12).background(.regularMaterial, in: Capsule()))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            let group = DispatchGroup()
            var urls: [URL] = []
            for p in providers where p.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { urls.append(url) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) { model.sendToPhone(urls) }
            return true
        }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let ids = confirmTrash { model.trashTransferFiles(ids) }
                confirmTrash = nil
            }
        } message: {
            Text("The files are removed from your Mac. You can get them back from the Trash.")
        }
        .navigationTitle("Transfers")
        .toolbar {
            ToolbarItemGroup {
                if transfers.pendingCount > 0 {
                    Button("Cancel All") { transfers.cancelAll() }
                }
                if !model.transferFiles(model.transferSelection).isEmpty {
                    Button { askTrash(model.transferSelection) } label: { Label("Move to Trash", systemImage: "trash") }
                        .help("Move selected files to Trash")
                }
                Button("Clear Finished") { transfers.clearFinished() }
                    .disabled(finished.isEmpty)
            }
        }
        .quickLookPreview($previewURL)
    }

    private func row(_ t: Transfer) -> some View {
        TransferRow(transfer: t, previewURL: $previewURL)
            .tag(t.id)
            .onDrag {
                // Drag a finished file out to Finder, Desktop, Mail…
                guard t.state == .done, let u = t.resultURL, FileManager.default.fileExists(atPath: u.path) else { return NSItemProvider() }
                return NSItemProvider(contentsOf: u) ?? NSItemProvider()
            }
    }

    private func askTrash(_ ids: Set<UUID>) {
        guard !model.transferFiles(ids).isEmpty else { return }
        confirmTrash = ids
    }

    private var trashTitle: String {
        let n = model.transferFiles(confirmTrash ?? []).count
        return n == 1 ? "Move this file to Trash?" : "Move \(n) files to Trash?"
    }
}

struct TransferRow: View {
    @EnvironmentObject var transfers: TransferManager
    @ObservedObject var transfer: Transfer
    @Binding var previewURL: URL?

    private var file: URL? {
        guard transfer.state == .done, let url = transfer.resultURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if transfer.state == .running {
                    if let f = transfer.fraction {
                        ProgressView(value: f).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: directionSymbol).imageScale(.small)
                    Text(subtitle).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var leading: some View {
        if let file {
            LocalThumbnail(url: file, size: 48)
                .onTapGesture { previewURL = file }
                .help("Click to preview")
        } else {
            // File-type icon (from the name's extension), with a small status badge
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (transfer.name as NSString).pathExtension) ?? .data))
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .opacity(transfer.state == .done || transfer.state == .running || transfer.state == .queued ? 1 : 0.5)
                .overlay(alignment: .bottomTrailing) {
                    if transfer.state != .running && transfer.state != .queued {
                        Image(systemName: stateSymbol)
                            .font(.system(size: 15))
                            .foregroundStyle(.white, stateColor)
                            .offset(x: 3, y: 3)
                    }
                }
        }
    }

    @ViewBuilder private var trailing: some View {
        if !transfer.isFinished {
            Button { transfers.cancel(transfer) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel")
        } else if let file {
            HStack(spacing: 2) {
                Button { previewURL = file } label: { Image(systemName: "eye") }
                    .help("Quick Look")
                Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "magnifyingglass") }
                    .help("Show in Finder")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private var isFailed: Bool { if case .failed = transfer.state { return true }; return false }

    private var subtitle: String {
        let time = transfer.created.formatted(date: .omitted, time: .shortened)
        switch transfer.state {
        case .queued, .running: return "\(transfer.verb) · \(transfer.statusText)"
        case .done: return "\(doneLabel) · \(transfer.totalBytes.byteString) · \(time)"
        default: return "\(transfer.statusText) · \(time)"
        }
    }

    private var doneLabel: String {
        switch transfer.kind {
        case .download: return "Copied to Mac"
        case .upload: return "Copied to phone"
        case .open: return "Opened"
        case .phoneCopy: return "Copied on phone"
        case .wifiReceive: return "Received wirelessly"
        case .wifiSend: return "Sent to phone"
        }
    }

    private var directionSymbol: String {
        switch transfer.kind {
        case .download, .wifiReceive, .open: return "arrow.down"
        case .upload, .wifiSend: return "arrow.up"
        case .phoneCopy: return "doc.on.doc"
        }
    }

    private var stateSymbol: String {
        switch transfer.state {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        default: return transfer.symbol
        }
    }

    private var stateColor: Color {
        switch transfer.state {
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Copying to Mac") {
                LabeledContent("Save files to") {
                    HStack {
                        Text(model.downloadFolder.path).lineLimit(1).truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Change…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { model.downloadFolderPath = u.path }
                        }
                    }
                }
                Toggle("Show in Finder when copying finishes", isOn: $model.revealAfterDownload)
            }
            Section("Browsing") {
                Toggle("Show hidden files (starting with “.”)", isOn: $model.showHidden)
            }
            Section("Android Platform Tools (adb)") {
                LabeledContent("Detected") {
                    Text(model.adbPath ?? "Not found").foregroundStyle(.secondary).textSelection(.enabled)
                }
                TextField("Custom adb path (optional)", text: $model.customADBPath)
                Button("Detect Again") { Task { await model.locateADB() } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 380)
    }
}

/// Finder-style preview of a file on the Mac (photos, videos, PDFs…); falls back to the file's icon.
struct LocalThumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .task(id: url) {
            let req = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: size * 2, height: size * 2),
                scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).nsImage
        }
    }
}
