import XCTest
@testable import Mindwire

final class ChatLinkTests: XCTestCase {
    func testWorkspacePathsAndSourceCitationsKeepTheRemoteContext() throws {
        let cases: [(String, String, Int?)] = [
            ("src/feature%20one.swift:42:7", "/projects/orbit/src/feature one.swift", 42),
            ("README.md:12", "/projects/orbit/README.md", 12),
            ("./src/../public/preview.png", "/projects/orbit/public/preview.png", nil),
            ("/tmp/preview.png", "/tmp/preview.png", nil),
            ("file:///home/alex/project/main.swift#L8-L12", "/home/alex/project/main.swift", 8),
            ("sandbox:/tmp/result.png", "/tmp/result.png", nil),
            ("~/Pictures/preview.png", "/home/alex/Pictures/preview.png", nil),
            ("src/main.swift#L20C4", "/projects/orbit/src/main.swift", 20),
            ("src/%D9%85%D8%B1%D8%AD%D8%A8%D8%A7.swift", "/projects/orbit/src/مرحبا.swift", nil),
            ("public/100%2525.png", "/projects/orbit/public/100%25.png", nil)
        ]
        for (value, path, line) in cases {
            guard case .file(let link) = try ChatLinkDestination.resolve(XCTUnwrap(URL(string: value))) else {
                return XCTFail("Expected a workspace file: \(value)")
            }
            XCTAssertEqual(try link.resolvedPath(root: "/projects/orbit", home: "/home/alex"), path)
            XCTAssertEqual(link.line, line)
        }
        XCTAssertThrowsError(try WorkspaceFileLink(path: "~/file.png").resolvedPath(root: "/projects/orbit", home: nil),
                             "Never resolve a workspace link against the phone's home")
    }

    func testWebLinksKeepQueriesFragmentsAndProtocolRelativeDestinations() throws {
        for value in ["https://mindwire.sh/docs?q=a%20b#setup", "http://localhost:3000/", "//example.com/docs"] {
            guard case .web(let web) = try ChatLinkDestination.resolve(XCTUnwrap(URL(string: value))) else {
                return XCTFail("Expected a web link")
            }
            XCTAssertEqual(web.absoluteString, value.hasPrefix("//") ? "https:" + value : value)
        }
    }

    func testOtherSchemesAndMissingPathsNeverBecomePhoneFileOrAppLaunches() throws {
        for value in ["javascript:alert(1)", "data:text/html,test", "ssh://host/path", "file://other-host/private/a.png", "#heading", "sandbox:relative.png"] {
            XCTAssertThrowsError(try ChatLinkDestination.resolve(XCTUnwrap(URL(string: value))), value)
        }
    }
}
