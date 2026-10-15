import SwiftUI
import UniformTypeIdentifiers

enum ProjectLibraryDragKind {
    case project, folder

    var type: UTType {
        UTType(exportedAs: "com.oblien.mindwire.library-\(self == .project ? "project" : "folder")", conformingTo: .data)
    }

    func provider(for id: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(id.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) {
            completion in completion(data, nil); return nil
        }
        return provider
    }

    func loadID(from providers: [NSItemProvider], perform action: @escaping (String) -> Void) {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let id = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in action(id) }
        }
    }
}

/// UIKit owns the lift, drag preview, autoscroll, and cancellation. A drop saves one reorder;
/// hovering never writes preferences or queues daemon edits. Payloads stay within this app.
private struct ProjectLibraryCardReorder: ViewModifier {
    let id: String
    let kind: ProjectLibraryDragKind
    let move: (String) -> Void
    var earlier: (() -> Void)?
    var later: (() -> Void)?
    var cornerRadius: CGFloat
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(.interaction, .rect(cornerRadius: cornerRadius))
            .contentShape([.dragPreview, .contextMenuPreview], .rect(cornerRadius: cornerRadius))
            .onDrag { kind.provider(for: id) }
            .onDrop(of: [kind.type], delegate: ProjectLibraryCardDrop(kind: kind, targeted: $targeted, move: move))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(targeted ? Palette.accent : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .accessibilityHint(t("projects.reorder.hint"))
            .accessibilityActions {
                if let earlier { Button(t("projects.reorder.earlier"), action: earlier) }
                if let later { Button(t("projects.reorder.later"), action: later) }
            }
    }
}

private struct ProjectLibraryCardDrop: DropDelegate {
    let kind: ProjectLibraryDragKind
    @Binding var targeted: Bool
    let move: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [kind.type]) }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        let providers = info.itemProviders(for: [kind.type])
        guard !providers.isEmpty else { return false }
        kind.loadID(from: providers, perform: move)
        return true
    }
}

extension View {
    /// The lifted view owns its surface and disclosure, so native previews never capture
    /// the List's rectangular background or the transparent gutter between cards.
    func projectLibraryCard(selected: Bool = false, showsDisclosure: Bool = true) -> some View {
        HStack(spacing: Spacing.md) {
            self
            if showsDisclosure {
                AppIcon(.chevronRight, size: 12)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(EntityCardStyle.padding)
        .background(EntityCardBackground(selected: selected))
        .contentShape(.interaction, .rect(cornerRadius: EntityCardStyle.cornerRadius))
    }

    func projectLibraryCardRow() -> some View {
        contentShape([.dragPreview, .contextMenuPreview], .rect(cornerRadius: EntityCardStyle.cornerRadius))
            .padding(.vertical, EntityCardStyle.spacing / 2)
            .navigationLinkIndicatorVisibility(.hidden)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }

    func projectLibraryCardReorder(id: String, kind: ProjectLibraryDragKind, cornerRadius: CGFloat = EntityCardStyle.cornerRadius,
                                   earlier: (() -> Void)? = nil, later: (() -> Void)? = nil,
                                   move: @escaping (String) -> Void) -> some View {
        modifier(ProjectLibraryCardReorder(id: id, kind: kind, move: move, earlier: earlier, later: later,
                                            cornerRadius: cornerRadius))
    }
}

/// Both layouts read exactly the same cached project metadata and activity indicators.
struct ProjectLibraryEntryLabel<Subtitle: View, IconContent: View, Accessory: View>: View {
    let name: String
    let layout: ProjectLibraryLayout
    var selected = false
    @ViewBuilder var subtitle: () -> Subtitle
    @ViewBuilder var icon: () -> IconContent
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        if layout == .list {
            listLabel
        } else {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    icon().frame(width: EntityCardStyle.iconSize, height: EntityCardStyle.iconSize).accessibilityHidden(true)
                    Spacer(minLength: 0)
                    gridAccessory
                }
                gridTitle
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(Spacing.lg)
            .background(EntityCardBackground(selected: selected))
            .contentShape(.rect(cornerRadius: EntityCardStyle.cornerRadius))
            .accessibilityElement(children: .combine)
        }
    }

    private var listLabel: some View {
        EntityRow(style: .card) { Text(name) } subtitle: { subtitle() } icon: { icon() } accessory: { accessory() }
    }

    private var gridTitle: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
            subtitle().font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var gridAccessory: some View {
        accessory().lineLimit(1).minimumScaleFactor(0.75)
    }
}

struct ProjectFolderTile: View {
    let folder: ProjectFolder
    let count: Int
    let iconImages: [UIImage]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                ProjectFolderIcon(images: iconImages, size: EntityCardStyle.iconSize)
                Spacer(minLength: 0)
                AppIcon(.chevronRight, size: 12).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(folder.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text(t(count == 1 ? "projects.folder.projectCountOne" : "projects.folder.projectCount", ["count": "\(count)"]))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(Spacing.lg)
        .background(EntityCardBackground())
        .contentShape(.rect(cornerRadius: EntityCardStyle.cornerRadius))
        .accessibilityElement(children: .combine)
    }
}

/// The same folder preview in cards, tiles, and pickers. Callers supply cached custom artwork;
/// missing custom icons leave empty slots rather than repeating the default project glyph.
struct ProjectFolderIcon: View {
    let images: [UIImage]
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 12 / 44, style: .continuous).fill(Palette.accentSoft)
            if images.isEmpty {
                AppIcon(.folderFilled, size: size * 25 / 44).foregroundStyle(Palette.accent)
            } else {
                Grid(horizontalSpacing: size * 3 / 44, verticalSpacing: size * 3 / 44) {
                    ForEach(0..<2, id: \.self) { row in
                        GridRow {
                            ForEach(0..<2, id: \.self) { column in
                                let index = row * 2 + column
                                Group {
                                    if images.indices.contains(index) { ProjectIconArtwork(image: images[index]) }
                                    else { Color.clear }
                                }
                                .frame(width: size * 15 / 44, height: size * 15 / 44)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
