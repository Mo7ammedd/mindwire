import XCTest
@testable import Mindwire

final class TransportTests: XCTestCase {
    func testSSHExecPreservesArgumentBoundariesAndQuotes() {
        let script = "printf '%s\\n' \"hello world\" && touch /tmp/done"
        let command = SSHConnection.commandString(["bash", "-lc", script])

        XCTAssertEqual(command, "'bash' '-lc' 'printf '\\''%s\\n'\\'' \"hello world\" && touch /tmp/done'")
    }

    func testSSHExecQuotesEmptyAndHostileArguments() {
        XCTAssertEqual(
            SSHConnection.commandString(["tool", "", "$(touch /tmp/nope)", "a'b"]),
            "'tool' '' '$(touch /tmp/nope)' 'a'\\''b'"
        )
    }
}
