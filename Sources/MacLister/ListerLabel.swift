import SwiftUI
import AppKit

/// The colours a lister label can have (the same names as button tints in buttons.json).
enum LabelPalette {
    static let names = ["blue", "green", "orange", "red", "purple", "teal", "pink", "yellow", "brown", "gray"]

    static func color(_ name: String?) -> Color? {
        switch name?.lowercased() {
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "purple": return .purple
        case "teal": return .teal
        case "pink": return .pink
        case "yellow": return .yellow
        case "brown": return .brown
        case "gray", "grey": return .gray
        default: return nil
        }
    }

    static func title(_ name: String) -> String { tr(name.prefix(1).uppercased() + name.dropFirst()) }
}

/// "Name This Lister…": an optional name and colour, so one lister among many is easy to find
/// (and to pick as the destination of a copy).
struct ListerLabelView: View {
    let initialName: String
    let initialColor: String?
    var onApply: (_ name: String, _ color: String?) -> Void
    var close: () -> Void

    @State private var name = ""
    @State private var color: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name This Lister").font(.title3.bold())
            Text("A short name helps you tell listers apart, for example “NAS” or “Backup”. It shows in the window title, next to the path and where you pick a destination.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            TextField("Name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(apply)

            VStack(alignment: .leading, spacing: 6) {
                Text("Color").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    swatch(nil)
                    ForEach(LabelPalette.names, id: \.self) { swatch($0) }
                }
            }

            HStack {
                if !initialName.isEmpty || initialColor != nil {
                    Button("Remove Name") { onApply("", nil); close() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("OK", action: apply).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            name = initialName
            color = initialColor
            DispatchQueue.main.async { focused = true }
        }
    }

    private func swatch(_ value: String?) -> some View {
        let fill = LabelPalette.color(value)
        return Button { color = value } label: {
            ZStack {
                Circle().fill(fill ?? Color.clear)
                Circle().stroke(Color.secondary.opacity(fill == nil ? 0.8 : 0.25), lineWidth: 1)
                if value == nil { Image(systemName: "slash.circle").font(.system(size: 12)).foregroundStyle(.secondary) }
                if color == value { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).opacity(value == nil ? 0 : 1) }
            }
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: color == value ? 2 : 0).padding(-3))
        }
        .buttonStyle(.plain)
        .help(value.map { LabelPalette.title($0) } ?? tr("No color"))
    }

    private func apply() {
        onApply(name.trimmingCharacters(in: .whitespacesAndNewlines), color)
        close()
    }
}

extension ListerViewController {
    func promptLabel() {
        guard let window = view.window else { return }
        let initialName = model.label, initialColor = model.labelColor
        SheetPresenter().present(on: window, size: NSSize(width: 400, height: 280)) { close in
            ListerLabelView(initialName: initialName, initialColor: initialColor, onApply: { [weak self] name, color in
                self?.model.setLabel(name, color: color)
            }, close: close)
        }
    }
}
