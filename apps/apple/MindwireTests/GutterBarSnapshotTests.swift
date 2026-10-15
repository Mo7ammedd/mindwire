import XCTest
import SwiftUI
import UIKit
@testable import Mindwire

/// Renders the agent onboarding visuals — the colored brand logo + the native install stepper — to
/// a PNG so we can confirm the Claude mark is terracotta (not white) and the stepper reads well.
final class AgentOnboardingSnapshotTests: XCTestCase {
    @MainActor
    func testIconAndStepperRender() throws {
        let steps = [
            DaemonStepResult(name: "git", status: "satisfied", output: nil),
            DaemonStepResult(name: "node", status: "satisfied", output: nil),
            DaemonStepResult(name: "Claude Code", status: "satisfied", output: nil),
        ]
        let view = VStack(spacing: 20) {
            HStack(spacing: 16) {
                AgentLogo(id: .claudeCode, size: 44)
                    .frame(width: 76, height: 76).background(Color.gray.opacity(0.15), in: .circle)
                AgentLogo(id: .claudeCode, size: 44, mono: true)
                    .frame(width: 76, height: 76).background(Color.gray.opacity(0.15), in: .circle)
            }
            // Working state — real install, with a progress bar + tool checks.
            DaemonPreparingView(activity: .installingTools, message: "Installing the agent CLI…", steps: steps)
                .frame(height: 220)
                .overlay(alignment: .topLeading) { Text("WORKING").font(.caption2).foregroundStyle(.secondary) }
            Divider()
            // Quiet state — the common re-open case: just a spinner, no progress bar.
            DaemonPreparingView(activity: .checking, message: nil)
                .frame(height: 120)
                .overlay(alignment: .topLeading) { Text("QUIET").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding()
        .frame(width: 390)
        .background(Color(.systemBackground))

        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 560)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: URL(fileURLWithPath: "/tmp/agentui.png"))
        print("AGENTUI_SNAPSHOT bytes=\(data.count)")
        XCTAssertGreaterThan(data.count, 1000)
    }
}

/// Renders the rich chat message view (markdown + fenced code) to a PNG for visual verification.
final class MessageContentSnapshotTests: XCTestCase {
    @MainActor
    func testMessageContentRenders() throws {
        let sample = """
        Here's the fix — use **async** and call `fetch()` before returning:

        ```swift
        func load() async -> Int {
            let value = await fetch()
            return value
        }
        ```

        See [the docs](https://example.com) for the full API.
        """
        let host = UIHostingController(rootView:
            MessageContentView(text: sample)
                .padding()
                .frame(width: 390, alignment: .leading)
                .background(Color(.systemBackground))
        )
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 420)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: URL(fileURLWithPath: "/tmp/chatmsg.png"))
        print("CHATMSG_SNAPSHOT bytes=\(data.count)")
        XCTAssertGreaterThan(data.count, 1000)
    }
}

/// Renders the editor's gutter-bar overlay with hardcoded changes and writes a PNG, to verify the
/// bars actually paint (and to eyeball alignment) without needing a live workspace/git backend.
final class GutterBarSnapshotTests: XCTestCase {
    @MainActor
    func testGutterBarsRender() throws {
        let sample = (1...24).map { "line \($0): let value = compute(\($0))" }.joined(separator: "\n")
        let tv = DiffGutterTextView(frame: CGRect(x: 0, y: 0, width: 390, height: 680))
        tv.configureForSnapshot(text: sample, dark: true)
        tv.editorChanges = EditorChanges(
            lineKinds: [2: .added, 3: .added, 4: .added, 9: .modified, 10: .modified, 16: .added],
            deletionAnchors: [13, 20]
        )

        let window = UIWindow(frame: tv.bounds)
        window.backgroundColor = .black
        window.addSubview(tv)
        window.makeKeyAndVisible()

        // Flush Runestone's (possibly async) layout so caret geometry + bars are ready.
        for _ in 0..<4 {
            tv.setNeedsLayout(); tv.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        let renderer = UIGraphicsImageRenderer(bounds: tv.bounds)
        let image = renderer.image { _ in tv.drawHierarchy(in: tv.bounds, afterScreenUpdates: true) }
        let data = try XCTUnwrap(image.pngData())
        let url = URL(fileURLWithPath: "/tmp/gutterbars.png")
        try data.write(to: url)
        print("SNAPSHOT_WRITTEN path=\(url.path) bytes=\(data.count) size=\(image.size) gutterWidth=\(tv.gutterWidth)")
        XCTAssertGreaterThan(data.count, 1000)
    }

    @MainActor
    func testDiffInEditorRenders() throws {
        let buffer = [
            "func load() {",
            "  let x = fetchOld()",
            "  let cached = store[key]",
            "  let x = await fetchNew()",
            "  return x",
            "}"
        ].joined(separator: "\n")
        let tv = DiffGutterTextView(frame: CGRect(x: 0, y: 0, width: 390, height: 680))
        // lines 2 & 3 removed (red), line 4 added (green) — a modified region
        tv.configureDiffForSnapshot(text: buffer, tints: [2: .removed, 3: .removed, 4: .added], dark: true)

        let window = UIWindow(frame: tv.bounds)
        window.backgroundColor = .black
        window.addSubview(tv)
        window.makeKeyAndVisible()
        for _ in 0..<4 {
            tv.setNeedsLayout(); tv.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        let renderer = UIGraphicsImageRenderer(bounds: tv.bounds)
        let image = renderer.image { _ in tv.drawHierarchy(in: tv.bounds, afterScreenUpdates: true) }
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: URL(fileURLWithPath: "/tmp/diffeditor.png"))
        print("DIFF_SNAPSHOT_WRITTEN bytes=\(data.count)")
        XCTAssertGreaterThan(data.count, 1000)
    }

    @MainActor
    func testDiffMarkersFollowWrappedLinesAndOnlyRenderTheViewport() async throws {
        var lines = (1...600).map { "line \($0): let value = compute(\($0))" }
        lines[2] = String(repeating: "long changed line 🧠 ", count: 20)
        let text = lines.joined(separator: "\n")
        let tints = Dictionary(uniqueKeysWithValues: (1...600).map {
            ($0, $0.isMultiple(of: 2) ? DiffTint.added : .removed)
        })
        let tv = DiffGutterTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        tv.configureDiffForSnapshot(text: text, tints: tints, dark: true)
        tv.isLineWrappingEnabled = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = tv.bounds
        let controller = UIViewController()
        controller.view = tv
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        func settle() async throws {
            tv.setNeedsLayout()
            tv.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            tv.layoutIfNeeded()
        }
        try await settle()
        let gutter = try XCTUnwrap(tv.subviews.compactMap { $0 as? DiffLineMarkerView }.first)
        let backdrop = try XCTUnwrap(tv.subviews.first { $0.accessibilityIdentifier == "editor.gutter.backdrop" })
        XCTAssertTrue(backdrop.isHidden, "No gutter backing is needed while code starts after the gutter")
        let source = text as NSString
        func caret(at text: String) throws -> CGRect {
            let range = source.range(of: text)
            XCTAssertNotEqual(range.location, NSNotFound)
            let position = try XCTUnwrap(tv.position(from: tv.beginningOfDocument, offset: range.location))
            return tv.caretRect(for: position)
        }
        let wrapped = try caret(at: lines[2])
        let next = try caret(at: lines[3])
        let marker = try XCTUnwrap(gutter.markers.first { abs($0.y + gutter.frame.minY - wrapped.minY) < 1 })
        XCTAssertEqual(marker.tint, .removed)
        XCTAssertEqual(marker.height, next.minY - wrapped.minY, accuracy: 1,
                       "The rail must cover every wrapped fragment of the changed line")
        XCTAssertGreaterThan(marker.height, wrapped.height * 2)

        tv.selectedRange = source.range(of: "compute(4)")
        let selection = tv.selectedRange
        tv.scrollRangeToVisible(source.range(of: "line 500:"))
        try await settle()
        let target = try caret(at: "line 500:")
        XCTAssertTrue(gutter.markers.contains {
            $0.tint == .added && abs($0.y + gutter.frame.minY - target.minY) < 1
        }, "The marker must follow its actual source line after a long scroll")
        XCTAssertLessThan(gutter.markers.count, 100, "Large diffs only draw the visible gutter")
        XCTAssertEqual(gutter.bounds.height, tv.bounds.height, accuracy: 1)
        XCTAssertEqual(tv.selectedRange, selection, "Gutter updates must preserve code selection")

        tv.theme = EditorTheme.onvo(fontSize: 20)
        tv.isLineWrappingEnabled = false
        tv.setContentOffset(CGPoint(x: 80, y: tv.contentOffset.y), animated: false)
        try await settle()
        XCTAssertEqual(gutter.font.pointSize, 20)
        XCTAssertEqual(gutter.frame.minX, tv.contentOffset.x, accuracy: 1,
                       "The gutter stays visible during horizontal scrolling")
        XCTAssertEqual(tv.selectedRange, selection)
        XCTAssertFalse(backdrop.isHidden, "The pinned gutter must obscure code scrolling underneath it")
        XCTAssertEqual(backdrop.frame.minX, tv.contentOffset.x, accuracy: 1)
        XCTAssertEqual(backdrop.frame.width, tv.gutterWidth, accuracy: 0.5,
                       "The solid background must end at the gutter edge")
        XCTAssertLessThan(try XCTUnwrap(tv.subviews.firstIndex(of: backdrop)),
                          try XCTUnwrap(tv.subviews.firstIndex(of: gutter)), "Markers stay above the solid background")
        XCTAssertFalse(backdrop.isUserInteractionEnabled, "The backing cannot intercept code selection")
        for dark in [true, false] {
            tv.overrideUserInterfaceStyle = dark ? .dark : .light
            let theme = dark ? EditorTheme.onvo(fontSize: 20) : EditorTheme.light(fontSize: 20)
            tv.theme = theme
            tv.backgroundColor = theme.backgroundColor
            tv.setBarColors(dark: dark)
            tv.highlightedRanges = CodeEditorView.diffHighlightRanges(for: text, tints: tints, dark: dark)
            try await settle()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let name = "mindwire-diff-horizontal-\(dark ? "dark" : "light")"
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        }
        tv.setContentOffset(CGPoint(x: 0, y: tv.contentOffset.y), animated: false)
        try await settle()
        XCTAssertTrue(backdrop.isHidden, "Returning to the left edge restores the transparent gutter")
        tv.diffTints = [:]
        try await settle()
        XCTAssertTrue(gutter.isHidden, "Returning to ordinary file content removes diff markers")
    }
}
