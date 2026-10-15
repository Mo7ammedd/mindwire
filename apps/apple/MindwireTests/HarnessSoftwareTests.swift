import XCTest
@testable import Mindwire

final class HarnessSoftwareTests: XCTestCase {
    func testManagedRepairActionIsAvailableForProbeFailureAndMismatch() {
        for state in ["incompatible", "unavailable"] {
            let software = DaemonHarnessSoftware(policyVersion: 1, installedVersion: "0.160.0", recommendedVersion: "0.155.0",
                compatibility: state, managed: true, updateAvailable: false, repairAvailable: true,
                requiresDaemonUpdate: false, catalogRevision: 1, catalogSource: "fixture", catalogStale: false)
            XCTAssertTrue(software.canUpdate)
        }
    }
}
