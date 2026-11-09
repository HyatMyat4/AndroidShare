import SwiftUI
import UniformTypeIdentifiers
import QuickLook

struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false
    @State private var renameText = ""
    @State private var folderName = "New Folder"
    @FocusState private var listFocused: Bool

    var body: some View {
        withDialogs(withCommands(core))
    }

    private var core: some View {
        VStack(spacing: 0) {
            PathBar()
            Divider()
            ZStack {
                if model.viewMode == .list { listView } else { GridBrowser() }
                if model.isLoading && model.items.isEmpty {
                    ProgressView("Reading phone…")
                } else if !model.isLoading && model.displayedItems.isEmpty {
                    emptyState
                }
                if dropTargeted { dropOverlay }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                model.handleDrop(providers)
            }
            Divider()
            StatusBar()
        }
    }

    private func withCommands<V: View>(_ v: V) -> some View {
        v
        .navigationTitle(model.breadcrumbs.last?.0 ?? "Phone")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search this folder")
        .toolbar { toolbar }
        .quickLookPreview($model.quickLookURL)
        .onKeyPress(.space) {
            guard !model.selection.isEmpty else { return .ignored }
            model.quickLook(); return .handled
        }
        .onKeyPress(.return) {
            guard !model.selection.isEmpty else { return .ignored }
            model.open(model.selection); return .handled
        }
        .onDeleteCommand { if !model.selection.isEmpty { model.pendingDelete = model.selectedFiles } }
    }

    private func withDialogs<V: View>(_ v: V) -> some View {
        v
        .sheet(item: $model.renaming) { f in
            NameSheet(title: "Rename", prompt: "New name for “\(f.name)”", text: $renameText, action: "Rename") {
                model.rename(f, to: renameText)
            }
            .onAppear { renameText = f.name }
        }
        .sheet(isPresented: $model.creatingFolder) {
            NameSheet(title: "New Folder", prompt: "Create a folder in “\(model.breadcrumbs.last?.0 ?? "")”", text: $folderName, action: "Create") {
                model.createFolder(named: folderName)
            }
            .onAppear { folderName = "New Folder" }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { !model.pendingDelete.isEmpty },
            set: { if !$0 { model.pendingDelete = [] } }
        )) {
            Button("Delete from Phone", role: .destructive) {
                model.delete(model.pendingDelete); model.pendingDelete = []
            }
        } message: {
            Text("This permanently removes the items from your phone. This can't be undone.")
        }
    }

    private var deleteTitle: String {
        let d = model.pendingDelete
        return d.count == 1 ? "Delete “\(d[0].name)”?" : "Delete \(d.count) items?"
    }

    // MARK: List

    private var listView: some View {
        Table(of: RemoteFile.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { f in
                HStack(spacing: 8) {
                    ThumbView(model: model, file: f, size: 22, corner: 3)
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                    if model.clipboard?.mode == .cut, model.clipboard?.paths.contains(f.path) == true {
                        Image(systemName: "scissors").foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer(minLength: 0)
                }
                .opacity(f.isHidden ? 0.55 : 1)
                .folderDropTarget(f, model: model)
            }
            .width(min: 220, ideal: 380)
            TableColumn("Date Modified", value: \.modified) { f in
                Text(f.modified.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 150, ideal: 200)
            TableColumn("Size", value: \.size) { f in
                Text(f.isDir ? "--" : f.size.byteString)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Kind", value: \.kind) { f in
                Text(f.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } rows: {
            ForEach(model.displayedItems) { f in
                TableRow(f).itemProvider { model.dragProvider(for: f) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            FileMenu(model: model, ids: ids)
        } primaryAction: { ids in
            model.open(ids)
        }
        .focused($listFocused)
        .onAppear { listFocused = true }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
            Text(model.searchText.isEmpty ? "This folder is empty" : "No matches for “\(model.searchText)”")
                .font(.title3).foregroundStyle(.secondary)
            if model.searchText.isEmpty {
                Text("Drag files here from Finder to copy them to your phone.")
                    .foregroundStyle(.tertiary)
            }
        }
        .allowsHitTesting(false)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                Label("Drop to copy into “\(model.breadcrumbs.last?.0 ?? "")”", systemImage: "arrow.down.to.line")
                    .font(.title2.bold())
                    .padding(16)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(10)
            .allowsHitTesting(false)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack).help("Back")
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward).help("Forward")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $model.viewMode) {
                Image(systemName: "list.bullet").tag(ViewMode.list).help("List")
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid).help("Thumbnails")
            }
            .pickerStyle(.segmented)

            Button { model.creatingFolder = true } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }.help("New folder on phone (⇧⌘N)")

            Button { model.uploadWithPicker() } label: {
                Label("Copy to Phone", systemImage: "square.and.arrow.up")
            }.help("Copy files from Mac to this phone folder (⌘U)")

            Button { model.download(model.selectedFiles) } label: {
                Label("Copy to Mac", systemImage: "square.and.arrow.down")
            }
            .disabled(model.selection.isEmpty)
            .help("Copy selected items to \(model.downloadFolder.lastPathComponent) (⌘D)")

            Button { model.pendingDelete = model.selectedFiles } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.selection.isEmpty)
            .help("Delete from phone (⌘⌫)")

            Button { model.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }.help("Refresh (⌘R) — changes on the phone also appear automatically")
        }
    }
}

// MARK: - Context menu

struct FileMenu: View {
    @ObservedObject var model: AppModel
    let ids: Set<String>

    var files: [RemoteFile] { model.items.filter { ids.contains($0.id) } }

    var body: some View {
        if files.isEmpty {
            Button("New Folder") { model.creatingFolder = true }
            Button("Copy Files to Phone…") { model.uploadWithPicker() }
            if model.clipboard != nil { Button("Paste") { model.paste() } }
            Divider()
            Button("Refresh") { model.refresh() }
        } else {
            Button("Open") { model.open(ids) }
            if files.count == 1, !files[0].isDir {
                Button("Quick Look") { model.selection = ids; model.quickLook() }
            }
            Divider()
            Button("Copy to Mac (\(model.downloadFolder.lastPathComponent))") { model.download(files) }
            Button("Copy to Mac…") { model.downloadWithPicker(files) }
            Divider()
            if files.count == 1 {
                Button("Rename…") { model.renaming = files[0] }
            }
            Button("Copy Path") { model.copyPaths(files) }
            Divider()
            Button("Cut") { model.setClipboard(.cut, files) }
            Button("Copy") { model.setClipboard(.copy, files) }
            if model.clipboard != nil, files.count == 1, files[0].isDir {
                Button("Paste into “\(files[0].name)”") { model.paste(into: files[0].path) }
            }
            Menu("Move to") {
                let here = model.foldersHere.filter { !ids.contains($0.id) }
                if !here.isEmpty {
                    Section("In this folder") {
                        ForEach(here) { d in
                            Button {
                                model.transferOnPhone(files.map(\.path), mode: .cut, into: d.path)
                            } label: { Label(d.name, systemImage: "folder") }
                        }
                    }
                }
                if model.canGoUp {
                    Button {
                        model.transferOnPhone(files.map(\.path), mode: .cut, into: RemotePath.parent(model.currentPath))
                    } label: { Label("Up one level", systemImage: "arrow.turn.left.up") }
                }
                Section("Places") {
                    ForEach(model.locations.filter { $0.path != model.currentPath }) { loc in
                        Button {
                            model.transferOnPhone(files.map(\.path), mode: .cut, into: loc.path)
                        } label: { Label(loc.title, systemImage: loc.symbol) }
                    }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { model.pendingDelete = files }
        }
    }
}

// MARK: - Path bar

struct PathBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless)
                .disabled(!model.canGoUp)
                .help("Enclosing folder (⌘↑)")
                .padding(.trailing, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let crumbs = model.breadcrumbs
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                        if i > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        }
                        Button {
                            model.go(c.1)
                        } label: {
                            HStack(spacing: 4) {
                                if i == 0 { Image(systemName: "internaldrive") }
                                Text(c.0)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .fontWeight(i == crumbs.count - 1 ? .semibold : .regular)
                        .foregroundStyle(i == crumbs.count - 1 ? .primary : .secondary)
                        .onDrop(of: [.fileURL, .item], isTargeted: nil) { model.handleDrop($0, to: c.1) }
                    }
                }
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var transfers: TransferManager

    var body: some View {
        HStack(spacing: 12) {
            let shown = model.displayedItems
            Text(summary(shown)).foregroundStyle(.secondary)
            Spacer()
            if let t = transfers.active {
                ActiveTransferInline(transfer: t)
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(model.justChanged ? Color.accentColor : .green)
                    .frame(width: 7, height: 7)
                    .scaleEffect(model.justChanged ? 1.6 : 1)
                    .animation(.spring(duration: 0.3), value: model.justChanged)
                Text(model.justChanged ? "Updated from phone" : "Live")
                    .foregroundStyle(.secondary)
            }
            .help("Changes made on the phone (rename, move, new photos…) show up here automatically.")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func summary(_ shown: [RemoteFile]) -> String {
        let sel = model.selectedFiles
        if !sel.isEmpty {
            let bytes = sel.reduce(Int64(0)) { $0 + $1.size }
            return "\(sel.count) of \(shown.count) selected" + (bytes > 0 ? " · \(bytes.byteString)" : "")
        }
        return "\(shown.count) item\(shown.count == 1 ? "" : "s")"
    }
}

struct ActiveTransferInline: View {
    @ObservedObject var transfer: Transfer
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: transfer.symbol).foregroundStyle(Color.accentColor)
            Text(transfer.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
            if let f = transfer.fraction {
                ProgressView(value: f).frame(width: 80)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

// MARK: - Shared bits

struct FileIcon: View {
    let file: RemoteFile
    let size: CGFloat
    var body: some View {
        Image(systemName: file.symbol)
            .font(.system(size: size * 0.85))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
    private var color: Color {
        switch file.category {
        case .folder: return .accentColor
        case .image: return .orange
        case .video: return .purple
        case .audio: return .pink
        case .apk: return .green
        default: return .secondary
        }
    }
}

struct NameSheet: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let action: String
    let onCommit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(prompt).foregroundStyle(.secondary).lineLimit(2)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .frame(width: 340)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            focused = true
        }
    }

    private func commit() {
        onCommit()
        dismiss()
    }
}

// MARK: - Drop onto a folder (phone files → move, Finder files → copy)

struct FolderDropTarget: ViewModifier {
    @ObservedObject var model: AppModel   // passed explicitly: Table cells don't reliably inherit EnvironmentObjects
    let file: RemoteFile

    func body(content: Content) -> some View {
        if file.isDir {
            content
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(model.dropTargetPath == file.path ? 0.35 : 0))
                        .padding(-3)
                )
                .onDrop(of: [.fileURL, .item], isTargeted: Binding(
                    get: { model.dropTargetPath == file.path },
                    set: { inside in
                        if inside { model.dropTargetPath = file.path }
                        else if model.dropTargetPath == file.path { model.dropTargetPath = nil }
                    }
                )) { providers in
                    model.handleDrop(providers, to: file.path)
                }
        } else {
            content
        }
    }
}

extension View {
    func folderDropTarget(_ f: RemoteFile, model: AppModel) -> some View { modifier(FolderDropTarget(model: model, file: f)) }
}
