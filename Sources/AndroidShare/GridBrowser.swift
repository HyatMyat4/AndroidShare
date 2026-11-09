import SwiftUI

struct GridBrowser: View {
    @EnvironmentObject var model: AppModel
    @State private var anchor: String?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.displayedItems) { f in
                    GridCell(file: f, selected: model.selection.contains(f.id))
                        .onTapGesture(count: 2) { model.open([f.id]) }
                        .onTapGesture { select(f) }
                        .onDrag { model.dragProvider(for: f) }
                        .folderDropTarget(f, model: model)
                        .contextMenu {
                            FileMenu(model: model, ids: model.selection.contains(f.id) ? model.selection : [f.id])
                        }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = [] }
        .contextMenu { FileMenu(model: model, ids: []) }
    }

    private func select(_ f: RemoteFile) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if model.selection.contains(f.id) { model.selection.remove(f.id) } else { model.selection.insert(f.id) }
            anchor = f.id
        } else if mods.contains(.shift), let a = anchor {
            let list = model.displayedItems.map(\.id)
            if let i = list.firstIndex(of: a), let j = list.firstIndex(of: f.id) {
                model.selection = Set(list[min(i, j)...max(i, j)])
            }
        } else {
            model.selection = [f.id]
            anchor = f.id
        }
    }
}

struct GridCell: View {
    @EnvironmentObject var model: AppModel
    let file: RemoteFile
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ThumbView(model: model, file: file, size: 104, corner: 8)
            .frame(width: 112, height: 112)
            .background(selected ? Color.secondary.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 10))

            Text(file.name)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(selected ? .white : .primary)
            if !file.isDir {
                Text(file.size.byteString).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 130)
        .contentShape(Rectangle())
    }
}
