import XCTest
@testable import Mindwire

@MainActor
final class ChatHandoffTests: XCTestCase {
    private func preview(digest: String = String(repeating: "a", count: 64)) throws -> DaemonHandoffPreview {
        let value: [String: Any] = [
            "source": ["chatId": "source", "agentId": "source-profile", "title": "Checkout"],
            "context": "Keep the API. Review rollback.", "truncated": true, "historySource": "native",
            "capsule": ["version": 1, "summary": ["text": "Keep the API"]], "digest": digest,
            "losses": [["code": "tool_output_omitted", "count": 1]],
        ]
        return try JSONDecoder().decode(DaemonHandoffPreview.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testLostAcknowledgementReusesExactReviewedPayloadAndDigest() async throws {
        let value = try preview()
        var requests: [ChatHandoffRequest] = []
        let draft = ChatHandoffDraft(agents: [], loadPreview: { value }, perform: { request in
            requests.append(request)
            if requests.count == 1 { throw URLError(.networkConnectionLost) }
            return request.newChatId
        })
        draft.targetAgentId = "codex-profile"
        draft.task = "Review checkout"
        await draft.load()
        draft.context = "Reviewed correction: preserve billing periods."
        let first = await draft.send()
        XCTAssertNil(first)
        draft.task = "An accidental edit while recovering"
        draft.context = "Do not replace the persisted request"
        let second = await draft.send()
        XCTAssertNotNil(second)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(requests[0].previewDigest, value.digest)
        XCTAssertEqual(requests[0].context, "Reviewed correction: preserve billing periods.")
        XCTAssertEqual(draft.preview?.losses?.first?.code, "tool_output_omitted")
    }

    func testChangedSourceRequiresAnotherReviewBeforeSubmitting() async throws {
        let original = try preview()
        let refreshed = try preview(digest: String(repeating: "b", count: 64))
        var loads = 0
        var requests: [ChatHandoffRequest] = []
        let draft = ChatHandoffDraft(agents: [], loadPreview: {
            loads += 1
            return loads == 1 ? original : refreshed
        }, perform: { request in
            requests.append(request)
            if requests.count == 1 {
                throw DaemonHTTPError(status: 409, message: "Refresh the handoff", code: "handoff_context_changed")
            }
            return request.newChatId
        })
        draft.targetAgentId = "codex-profile"
        draft.task = "Review checkout"
        await draft.load()
        draft.context = "My additional constraint: keep billing periods unchanged."
        let rejected = await draft.send()
        XCTAssertNil(rejected)
        XCTAssertNil(draft.preview)
        XCTAssertNil(draft.submitted)
        XCTAssertFalse(draft.canSubmit)
        await draft.load()
        XCTAssertEqual(draft.previousReview, "My additional constraint: keep billing periods unchanged.")
        XCTAssertEqual(draft.context, refreshed.context)
        let accepted = await draft.send()
        XCTAssertNotNil(accepted)
        XCTAssertEqual(requests[1].previewDigest, refreshed.digest)
        XCTAssertNotEqual(requests[1].newChatId, requests[0].newChatId)
    }
}
