import SwiftUI

/// Display preferences shared by every file tree, independent of its data source.
struct FileTreePreferences: DynamicProperty {
    static let horizontalRange = 8.0...28.0
    static let verticalRange = 2.0...14.0
    static let defaultHorizontal = 12.0
    static let defaultVertical = 7.0
    @AppStorage("mindwire.files.tree.horizontal") var horizontal = defaultHorizontal
    @AppStorage("mindwire.files.tree.vertical") var vertical = defaultVertical
    @AppStorage("mindwire.files.tree.compactFolders") var compactFolders = true

    var indentation: CGFloat { Self.clamp(horizontal, in: Self.horizontalRange, fallback: Self.defaultHorizontal) }
    var rowPadding: CGFloat { Self.clamp(vertical, in: Self.verticalRange, fallback: Self.defaultVertical) }
    var labelGap: CGFloat { indentation / 3 }
    var horizontalBinding: Binding<Double> { Binding(get: { Double(indentation) }, set: { horizontal = $0 }) }
    var verticalBinding: Binding<Double> { Binding(get: { Double(rowPadding) }, set: { vertical = $0 }) }

    func reset() {
        horizontal = Self.defaultHorizontal
        vertical = Self.defaultVertical
        compactFolders = true
    }

    private static func clamp(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> CGFloat {
        CGFloat(value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback)
    }
}

struct FileTreeSettingsSheet: View {
    private var preferences = FileTreePreferences()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            Form {
                Section(t("files.tree.preview")) {
                    FileTree(entries: Self.roots, source: .snapshot(Self.children), expansion: { _ in .constant(true) },
                             appearance: { _ in FileTreeAppearance() }, onOpen: { _ in },
                             accessory: { _ in EmptyView() }, decoration: { _, _ in EmptyModifier() })
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                Section {
                    Toggle(t("files.tree.compact"), isOn: preferences.$compactFolders)
                        .accessibilityIdentifier("files.tree.compact")
                } footer: { Text(t("files.tree.compactHelp")) }
                Section {
                    spacingControl(t("files.tree.horizontal"), value: preferences.horizontalBinding,
                                   range: FileTreePreferences.horizontalRange, step: 2, id: "horizontal")
                    spacingControl(t("files.tree.vertical"), value: preferences.verticalBinding,
                                   range: FileTreePreferences.verticalRange, step: 1, id: "vertical")
                } footer: { Text(t("files.tree.shared")) }
            }
            .environment(\.defaultMinListRowHeight, 24)
            .navigationTitle(t("files.tree.customize"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .topBarLeading) {
                    Button(t("files.tree.resetButton")) { preferences.reset() }.tint(.primary)
                        .accessibilityLabel(t("files.tree.reset"))
                        .accessibilityIdentifier("files.tree.reset")
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button(t("common.done")) { dismiss() }.tint(.primary)
                }
            }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(620), .large])
        .presentationDragIndicator(.visible)
    }

    private func spacingControl(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                                step: Double, id: String) -> some View {
        VStack(spacing: Spacing.sm) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) pt").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step) { Text(title) }
                .accessibilityValue("\(Int(value.wrappedValue)) points")
                .accessibilityIdentifier("files.tree.\(id)")
        }
        .padding(.vertical, Spacing.xs)
    }

    private static let roots = [FileEntry(name: "apps", path: "apps", type: .dir)]
    private static let children: [String: [FileEntry]] = [
        "apps": [.init(name: "src", path: "apps/src", type: .dir)],
        "apps/src": [.init(name: "modules", path: "apps/src/modules", type: .dir)],
        "apps/src/modules": [.init(name: "index.ts", path: "apps/src/modules/index.ts", type: .file),
                             .init(name: "styles.css", path: "apps/src/modules/styles.css", type: .file)]
    ]
}
