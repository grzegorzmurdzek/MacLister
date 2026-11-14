import SwiftUI
import AppKit

/// Copy As / Move As (Directory Opus): copy or move the selection and give the items new names in the same step.
enum CopyAsRules {
    /// Why `name` cannot be used, or nil. `others` are the names the other items get; `existing` is true when an item
    /// of that name would replace the original itself (same folder, same name).
    static func problem(for name: String, others: [String], sameFolderAsSource: Bool, originalName: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return tr("The name is empty") }
        if trimmed.contains("/") { return tr("A name cannot contain /") }
        if trimmed == "." || trimmed == ".." { return tr("This name is not allowed") }
        if others.contains(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return tr("Two items would get the same name")
        }
        if sameFolderAsSource, trimmed == originalName { return tr("Choose another name: this is the same folder") }
        return nil
    }
}

struct CopyAsView: View {
    let kind: TransferKind
    let sources: [URL]
    let destinationName: String
    let sameFolder: Bool
    var onApply: ([URL: String]) -> Void
    var close: () -> Void

    @State private var names: [String]

    init(kind: TransferKind, sources: [URL], destinationName: String, sameFolder: Bool,
         onApply: @escaping ([URL: String]) -> Void, close: @escaping () -> Void) {
        self.kind = kind
        self.sources = sources
        self.destinationName = destinationName
        self.sameFolder = sameFolder
        self.onApply = onApply
        self.close = close
        _names = State(initialValue: sources.map(\.lastPathComponent))
    }

    private func problem(at index: Int) -> String? {
        let others = names.indices.filter { $0 != index }.map { names[$0] }
        return CopyAsRules.problem(for: names[index], others: others, sameFolderAsSource: sameFolder,
                                   originalName: sources[index].lastPathComponent)
    }

    private var allValid: Bool { names.indices.allSatisfy { problem(at: $0) == nil } }

    /// Only the items that really get another name.
    private var renames: [URL: String] {
        var result: [URL: String] = [:]
        for (index, source) in sources.enumerated() {
            let name = names[index].trimmingCharacters(in: .whitespaces)
            if name != source.lastPathComponent { result[source] = name }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .copy ? tr("Copy As") : tr("Move As")).font(.headline)
            Text(kind == .copy ? tr("Copies the items into “%@” under the names below.", destinationName)
                               : tr("Moves the items into “%@” under the names below.", destinationName))
                .font(.callout).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sources.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 2) {
                            if sources.count > 1 {
                                Text(sources[index].lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            TextField("", text: $names[index]).textFieldStyle(.roundedBorder)
                            if let problem = problem(at: index) {
                                Text(problem).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 260)

            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(kind == .copy ? tr("Copy") : tr("Move")) { onApply(renames); close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allValid)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

extension ListerViewController {
    /// Copy As / Move As: like F5 / F6, but asks for the new names first. Without a destination lister the items go
    /// into this lister's own folder (a copy under another name).
    func startTransferAs(_ kind: TransferKind) {
        let manager = ListerManager.shared
        let sourceModel = manager.sourceController?.model ?? model
        let destinationModel = manager.destinationController?.model ?? sourceModel
        let what = kind == .copy ? tr("Copy As") : tr("Move As")
        if sourceModel.isRemote || destinationModel.isRemote {
            flash(tr("Not available on a server yet: %@", what))
            return
        }
        guard !destinationModel.isVirtual else {
            model.errorMessage = tr("Cannot copy or move into “%@”: choose a folder as the destination", destinationModel.displayName)
            return
        }
        let items = sourceModel.selectedURLs
        guard !items.isEmpty else {
            model.errorMessage = tr("Nothing selected in the source lister")
            return
        }
        guard items.allSatisfy({ $0.scheme != VirtualPlace.scheme }) else {
            model.errorMessage = tr("Servers and computers in the Shared list cannot be copied: open them first")
            return
        }
        if kind == .move, refuseIfBusy(items) { return }
        guard let window = view.window else { return }
        model.errorMessage = nil
        let folder = destinationModel.url
        let sameFolder = items.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path }
        var shown: [ListerModel] = [sourceModel]
        if destinationModel !== sourceModel { shown.append(destinationModel) }
        let models = shown
        SheetPresenter().present(on: window, size: NSSize(width: 440, height: min(480, 190 + 70 * min(items.count, 4)))) { close in
            CopyAsView(kind: kind, sources: items, destinationName: destinationModel.displayName, sameFolder: sameFolder,
                       onApply: { [weak self] names in
                           self?.beginTransfer(kind, items: items, into: folder, showingIn: models, names: names)
                       }, close: close)
        }
    }
}
