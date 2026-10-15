import XCTest
import SwiftUI
@testable import Mindwire

@MainActor
final class AppIconTests: XCTestCase {
    func testEveryBundledIconHasTransparentMarginsAndVisibleTemplateArtwork() throws {
        for name in AppIconName.allCases {
            let source = try XCTUnwrap(UIImage(named: name.assetName), name.rawValue)
            XCTAssertEqual(source.renderingMode, .alwaysTemplate, name.rawValue)
            let image = AppIconImages.image(name, size: 24, scale: 3)
            XCTAssertEqual(image.size.width, 24, name.rawValue)
            XCTAssertEqual(image.renderingMode, .alwaysTemplate, name.rawValue)
            let raster = try pixels(image)
            let visible = stride(from: 3, to: raster.data.count, by: 4).filter { raster.data[$0] > 16 }
            XCTAssertGreaterThan(visible.count, 12, name.rawValue)
            XCTAssertLessThan(visible.count, raster.width * raster.height, name.rawValue)
            if name.artwork.inset == 0 {
                let xs = visible.map { ($0 / 4) % raster.width }
                let ys = visible.map { ($0 / 4) / raster.width }
                let inkWidth = try XCTUnwrap(xs.max()) - XCTUnwrap(xs.min()) + 1
                let inkHeight = try XCTUnwrap(ys.max()) - XCTUnwrap(ys.min()) + 1
                XCTAssertGreaterThanOrEqual(max(inkWidth, inkHeight), raster.width - 4,
                    "Source padding must not make the visible icon smaller: \(name.rawValue)")
            }
            for x in 0..<raster.width {
                XCTAssertEqual(raster.data[x * 4 + 3], 0, name.rawValue)
                XCTAssertEqual(raster.data[((raster.height - 1) * raster.width + x) * 4 + 3], 0, name.rawValue)
            }
        }
    }

    func testRasterCacheReusesImagesAndOnlyMirrorsDirectionalArtwork() throws {
        let first = AppIconImages.image(.terminal, size: 17, scale: 3)
        XCTAssertTrue(first === AppIconImages.image(.terminal, size: 17, scale: 3))
        XCTAssertTrue(first === AppIconImages.image(.terminal, size: 17, scale: 3, mirrored: true))
        XCTAssertFalse(first === AppIconImages.image(.terminal, size: 24, scale: 3))
        let left = try pixels(AppIconImages.image(.chevronRight, size: 24, scale: 3))
        let right = try pixels(AppIconImages.image(.chevronRight, size: 24, scale: 3, mirrored: true))
        for y in 0..<left.height {
            for x in 0..<left.width {
                XCTAssertLessThanOrEqual(abs(Int(left.data[(y * left.width + x) * 4 + 3]) -
                    Int(right.data[(y * left.width + left.width - 1 - x) * 4 + 3])), 1)
            }
        }
    }

    func testFontDynamicTypeAndTemplateTintReachTheNativeImage() throws {
        let small = try render(AppIcon(.folder).font(.caption2))
        let standard = try render(AppIcon(.folder).font(.body))
        let large = try render(AppIcon(.folder).font(.body).environment(\.dynamicTypeSize, .accessibility3))
        XCTAssertEqual(standard.size.width, 22, accuracy: 0.5)
        XCTAssertLessThan(small.size.width, standard.size.width)
        XCTAssertGreaterThan(large.size.width, standard.size.width * 1.5)
        let custom = try render(AppIcon(.terminal, size: 32).font(.largeTitle)
            .imageScale(.large).environment(\.dynamicTypeSize, .accessibility3))
        XCTAssertEqual(custom.size.width, 32, accuracy: 0.5)
        let red = try pixels(render(AppIcon(.trash, size: 24).foregroundStyle(Color.red)))
        let expected = try pixels(render(Rectangle().fill(Color.red).frame(width: 1, height: 1)))
        let colored = stride(from: 0, to: red.data.count, by: 4).filter { red.data[$0 + 3] > 128 }
        XCTAssertFalse(colored.isEmpty)
        for offset in colored {
            for channel in 0..<3 {
                let component = Int(expected.data[channel]) * Int(red.data[offset + 3]) / 255
                XCTAssertLessThanOrEqual(abs(Int(red.data[offset + channel]) - component), 2)
            }
        }
    }

    func testNativeMenuAndTabItemsKeepTheirImagesAndDestructiveRole() async throws {
        let fixture = TabView {
            Tab {
                NavigationStack {
                    Form {
                        ForEach(ProjectTool.allCases) { tool in
                            ProjectToolButton(tool: tool) {}
                        }
                    }
                    .navigationTitle("Projects")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            AppMenu {
                                Button("Open Files", icon: .folder) {}
                                Button("Rename", icon: .edit) {}
                                Button("Copy", icon: .copy) {}
                                DestructiveButton("Delete Project", icon: .trash) {}
                            } label: { AppIcon(.more).foregroundStyle(.primary) }
                            .accessibilityLabel("Project Actions")
                        }
                    }
                }
            } label: { Label("Projects", icon: .project) }
            Tab { Color.clear } label: { Label("Agents", icon: Icon.agents) }
            Tab { Color.clear } label: { Label("Workspaces", icon: Icon.workspace) }
            Tab { Color.clear } label: { Label("Settings", icon: .settings) }
        }.tint(Palette.accent)
        let (host, window) = try host(fixture)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(700))
        let controllers = descendants(host)
        let tab = try XCTUnwrap(controllers.compactMap { $0 as? UITabBarController }.first)
        let items = try XCTUnwrap(tab.tabBar.items)
        XCTAssertEqual(items.count, 4)
        for item in items {
            let image = try XCTUnwrap(item.image, item.title ?? "Tab")
            XCTAssertLessThanOrEqual(image.size.width, 32)
            XCTAssertGreaterThan(image.size.width, 10)
        }
        try snapshot(host, name: "mindwire-custom-icons-native-controls")
        let button = try AgentManagementTestUI.button(in: host)
        button.performPrimaryAction()
        let interaction = try XCTUnwrap(button.contextMenuInteraction)
        defer { interaction.dismissMenu() }
        var menuActions: [UIAction] = []
        for _ in 0..<100 {
            interaction.updateVisibleMenu { menu in
                menuActions = AgentManagementTestUI.actions(in: menu)
                return menu
            }
            if !menuActions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let open = try XCTUnwrap(menuActions.first { $0.title == "Open Files" }, "Native menu actions: \(menuActions)")
        let delete = try XCTUnwrap(menuActions.first { $0.title == "Delete Project" })
        XCTAssertNotNil(open.image)
        XCTAssertNotNil(delete.image)
        XCTAssertTrue(delete.attributes.contains(.destructive))
        for action in menuActions {
            let icon = try XCTUnwrap(action.image, action.title)
            XCTAssertEqual(icon.size.width, 22, accuracy: 0.5, "Native menu artwork must fit its compact slot: \(action.title)")
        }
        try await Task.sleep(for: .milliseconds(350))
        try menuSnapshot(window)
    }

    func testCatalogGalleryInLightAndDarkAppearance() throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = VStack(spacing: 18) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(88), spacing: 6), count: 8), spacing: 12) {
                    ForEach(AppIconName.allCases, id: \.self) { name in
                        VStack(spacing: 6) {
                            AppIcon(name, size: 24).foregroundStyle(.primary)
                            Text(name.rawValue).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(width: 88, height: 52)
                    }
                }
                HStack(spacing: 24) {
                    Label("Files", icon: .folder).foregroundStyle(Palette.accent)
                    Label("Ready", icon: .checkCircle).foregroundStyle(.green)
                    Label("Delete", icon: .trash).foregroundStyle(.red)
                }
            }
            .padding(20)
            .background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, scheme)
            let image = try render(view)
            let name = "mindwire-custom-icons-\(scheme)"
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png"))
        }
    }

    private func render<V: View>(_ view: V) throws -> UIImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }

    private func pixels(_ image: UIImage) throws -> (data: [UInt8], width: Int, height: Int) {
        let cg = try XCTUnwrap(image.cgImage)
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try data.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return (data, cg.width, cg.height)
    }

    private func host<V: View>(_ view: V) throws -> (UIViewController, UIWindow) {
        let controller = UIHostingController(rootView: view.labelIconToTitleSpacing(Spacing.md))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller; window.makeKeyAndVisible()
        return (controller, window)
    }
    private func descendants(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap(descendants)
    }
    private func snapshot(_ host: UIViewController, name: String) throws {
        let image = ChatFeedSnapshot.image(host)
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png"))
    }

    private func menuSnapshot(_ window: UIWindow) throws {
        let scene = try XCTUnwrap(window.windowScene)
        let windows = scene.windows.enumerated().filter { !$0.element.isHidden && $0.element.alpha > 0 }
            .sorted { left, right in
                left.element.windowLevel == right.element.windowLevel
                    ? left.offset < right.offset : left.element.windowLevel < right.element.windowLevel
            }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            for (_, overlay) in windows {
                overlay.drawHierarchy(in: overlay.convert(overlay.bounds, to: scene.coordinateSpace), afterScreenUpdates: true)
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "mindwire-native-menu-icons"; attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("mindwire-native-menu-icons.png"))
    }
}
