import Foundation
import Observation

/// Computer selection is not readiness. Only a verified service and authoritative
/// workspace sync may unlock account setup, including when resuming onboarding.
@MainActor @Observable
final class AssistantComputerPreparation {
    private(set) var error: String?
    private(set) var readyWorkspaceID: String?
    private var requestID = UUID()

    func reset() {
        requestID = UUID()
        readyWorkspaceID = nil
        error = nil
    }

    func prepare(_ workspaceID: String,
                 using prepare: @MainActor (String) async throws -> Void) async -> Bool {
        reset()
        let request = requestID
        do {
            try await prepare(workspaceID)
            try Task.checkCancellation()
            guard requestID == request else { return false }
            readyWorkspaceID = workspaceID
            return true
        } catch {
            guard requestID == request else { return false }
            if !error.isRequestCancellation { self.error = error.localizedDescription }
            return false
        }
    }
}
