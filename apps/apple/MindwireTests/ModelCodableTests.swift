import XCTest
@testable import Mindwire

/// Round-trip the discriminated-union models against their TS wire shapes.
final class ModelCodableTests: XCTestCase {
    private let enc = JSONEncoder()
    private let dec = JSONDecoder()

    func testAgentRuntimeCloudRoundTrip() throws {
        let json = #"{"kind":"cloud","workspaceId":"ws_1"}"#.data(using: .utf8)!
        let r = try dec.decode(AgentRuntime.self, from: json)
        XCTAssertEqual(r.workspaceId, "ws_1")
        XCTAssertTrue(r.isCloud)
        let back = try dec.decode(AgentRuntime.self, from: try enc.encode(r))
        XCTAssertEqual(back, r)
    }

    func testAgentRuntimeServerRoundTrip() throws {
        let r = AgentRuntime.serverRuntime("srv_9")
        let back = try dec.decode(AgentRuntime.self, from: try enc.encode(r))
        XCTAssertEqual(back.serverId, "srv_9")
    }

    func testConnectionFlatDiscriminator() throws {
        let json = #"{"id":"c1","name":"box","type":"ssh","host":"h","port":22,"username":"u","auth":{"kind":"agent"},"createdAt":"t"}"#.data(using: .utf8)!
        let c = try dec.decode(Connection.self, from: json)
        XCTAssertEqual(c.type, .ssh)
        XCTAssertEqual(c.remote?.host, "h")
        // Re-encode keeps the flat shape (type at top level).
        let obj = try JSONSerialization.jsonObject(with: try enc.encode(c)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "ssh")
    }

    func testAgentStatusRawValues() {
        XCTAssertEqual(AgentStatus.awaitingInput.rawValue, "awaiting_input")
    }

    func testLegacySandboxReferencesDecodeAndReencodeAsWorkspace() throws {
        let json = #"{"id":"p1","name":"Demo","sandboxId":"ws1","path":"/repo","createdAt":"t"}"#.data(using: .utf8)!
        let project = try dec.decode(Project.self, from: json)
        XCTAssertEqual(project.workspaceId, "ws1")

        let encoded = try JSONSerialization.jsonObject(with: enc.encode(project)) as? [String: Any]
        XCTAssertEqual(encoded?["workspaceId"] as? String, "ws1")
        XCTAssertNil(encoded?["sandboxId"])
    }

    func testLegacyWorkspaceStoreIsMigrated() throws {
        let suite = "MindwireTests.legacy-workspaces.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = #"[{"id":"ws1","name":"Legacy","runtime":{"kind":"server","serverId":"srv1"},"createdAt":"t"}]"#.data(using: .utf8)!
        defaults.set(legacy, forKey: StorageKey.legacySandboxes)

        let stores = Stores(defaults: defaults)
        XCTAssertEqual(stores.workspaces.get("ws1")?.name, "Legacy")
        XCTAssertNotNil(defaults.data(forKey: StorageKey.workspaces))
    }

    func testMonthlyComputerPreservesSavedPriceAndOpaqueAccountIdentity() throws {
        let computer = try dec.decode(CloudComputer.self, from: Data(#"{"id":"computer_1","name":"Mac + Xcode","state":"ready","plan":{"id":"max","name":"Max","monthlyCents":9900,"vcpus":8,"memoryMb":24576,"diskGb":240},"workspaceId":"vm_1","checkout":null,"subscription":{"status":"active","paidThrough":"2026-11-18T00:00:00Z","cancelAtPeriodEnd":true}}"#.utf8))
        XCTAssertEqual(computer.plan.memoryMb, 24576)
        XCTAssertEqual(computer.plan.diskGb, 240)
        XCTAssertEqual(computer.plan.monthlyCents, 9900)
        XCTAssertTrue(try XCTUnwrap(computer.subscription).cancelAtPeriodEnd)
        let status = try dec.decode(AuthStatus.self, from: Data(#"{"authenticated":true,"user":{"id":"mindwire-user_opaque","email":"owner@example.test","name":"Owner"}}"#.utf8))
        XCTAssertEqual(status.user?.id, "mindwire-user_opaque")
    }

    #if DEBUG
    func testAPILogRedactsCredentials() {
        let input = #"{"success":true,"token":"eyJabc.def.ghi","access_token":"ghp_secret123","refresh_token":"onp_secret456"}"#
        let redacted = APILog.redact(input)

        XCTAssertFalse(redacted.contains("eyJabc.def.ghi"))
        XCTAssertFalse(redacted.contains("ghp_secret123"))
        XCTAssertFalse(redacted.contains("onp_secret456"))
        XCTAssertTrue(redacted.contains(#""token":"…""#))
    }
    #endif

    func testDaemonCatalogAcceptsFutureAdaptersWithoutAnAppUpdate() throws {
        let json = #"{"version":"2","agents":[{"id":"future-agent","name":"Future Agent","tagline":"Published by mindwired","command":"future"}]}"#.data(using: .utf8)!
        let catalog = try dec.decode(DaemonCatalog.self, from: json)
        XCTAssertEqual(catalog.agents.first?.id.rawValue, "future-agent")
    }

    func testFoundryAuthSchemaSupportsPrimaryAndAlternativeInputs() throws {
        let json = #"""
        {"id":"azureFoundry","label":"Microsoft Foundry","fields":[
          {"key":"azureBaseUrl","label":"Endpoint URL","type":"text","required":true,"requiredUnless":["azureResource"],"help":"Use the OpenAI v1 endpoint."},
          {"key":"azureApiKey","label":"API key","type":"secret","required":true,"requiredUnless":["azureAuthToken"]},
          {"key":"azureModel","label":"Deployment name","type":"text","required":true},
          {"key":"azureResource","label":"Resource name instead of URL","type":"text","advanced":true},
          {"key":"azureAuthToken","label":"Entra ID token instead of API key","type":"secret","advanced":true}
        ]}
        """#.data(using: .utf8)!
        let method = try dec.decode(DaemonAuthMethod.self, from: json)
        XCTAssertFalse(method.interactive)
        XCTAssertEqual(method.fields.filter { $0.advanced != true }.map(\.key),
                       ["azureBaseUrl", "azureApiKey", "azureModel"])
        XCTAssertEqual(method.fields.first?.help, "Use the OpenAI v1 endpoint.")

        let validInputs = [
            ["azureBaseUrl": "https://resource.services.ai.azure.com/openai/v1", "azureApiKey": "key", "azureModel": "deployment"],
            ["azureResource": "resource", "azureAuthToken": "token", "azureModel": "deployment"]
        ]
        for values in validInputs {
            XCTAssertTrue(method.fields.allSatisfy { $0.hasRequiredValue(values: values) })
        }
        for values in [[:], ["azureModel": "deployment"],
                       ["azureResource": " \n ", "azureAuthToken": "token", "azureModel": "deployment"],
                       ["azureResource": "resource", "azureAuthToken": "token", "azureModel": " \n "]] {
            XCTAssertFalse(method.fields.allSatisfy { $0.hasRequiredValue(values: values) })
        }
    }

    func testLegacyAuthSchemaStillDecodesAndValidates() throws {
        let json = #"{"id":"apiKey","label":"API key","fields":[{"key":"apiKey","label":"API key","type":"secret","required":true}]}"#.data(using: .utf8)!
        let method = try dec.decode(DaemonAuthMethod.self, from: json)
        let field = try XCTUnwrap(method.fields.first)
        XCTAssertNil(field.advanced)
        XCTAssertNil(field.requiredUnless)
        XCTAssertFalse(field.hasRequiredValue(values: [:]))
        XCTAssertTrue(field.hasRequiredValue(values: ["apiKey": "key"]))

        let login = try dec.decode(DaemonAuthMethod.self, from: Data(#"{"id":"login","label":"Sign in","interactive":true}"#.utf8))
        XCTAssertTrue(login.interactive)
        XCTAssertTrue(login.fields.isEmpty)
        XCTAssertTrue(login.sections.isEmpty)
        XCTAssertEqual(method.form.visibleSections([:]).first?.title, "API key")
        XCTAssertTrue(method.form.isValid(["apiKey": "key"]))
    }

    private func conditionalAuthMethod() throws -> DaemonAuthMethod {
        // An arbitrary future provider exercises the same renderer without provider-specific keys.
        let json = #"""
        {"id":"future-cloud","label":"Cloud","fields":[
          {"key":"endpointType","label":"Endpoint","type":"select","required":true,"default":"url","presentation":"segmented","options":[{"value":"url","label":"URL"},{"value":"resource","label":"Resource name"}]},
          {"key":"url","label":"URL","type":"text","required":true,"inputMode":"url","visibleWhen":{"key":"endpointType","equals":"url"},"help":"URL help"},
          {"key":"resource","label":"Resource name","type":"text","required":true,"visibleWhen":{"key":"endpointType","equals":"resource"},"help":"Resource help"},
          {"key":"authType","label":"Authentication","type":"select","required":true,"default":"key","presentation":"segmented","options":[{"value":"key","label":"API key"},{"value":"token","label":"Token"},{"value":"identity","label":"Sign-in","help":"Uses the workspace identity."}]},
          {"key":"key","label":"API key","type":"secret","required":true,"visibleWhen":{"key":"authType","equals":"key"}},
          {"key":"token","label":"Token","type":"secret","required":true,"visibleWhen":{"key":"authType","equals":"token"}},
          {"key":"deployment","label":"Deployment name","type":"text","required":true}
        ],"sections":[
          {"id":"connection","title":"Connection details","fieldKeys":["endpointType","url","resource"]},
          {"id":"authentication","title":"Authentication","fieldKeys":["authType","key","token"]},
          {"id":"deployment","title":"Deployment name","fieldKeys":["deployment"]}
        ]}
        """#
        return try dec.decode(DaemonAuthMethod.self, from: Data(json.utf8))
    }

    func testAuthDefaultsControlVisibleInputsAndSubmission() throws {
        let method = try conditionalAuthMethod()
        let drafts = ["url": " https://example.test ", "key": "new-key", "deployment": "model",
                      "resource": "old-resource", "token": "old-token", "unknownSecret": "ignored"]
        XCTAssertTrue(method.form.isValid(drafts))
        XCTAssertEqual(method.form.submissionValues(drafts), [
            "endpointType": "url", "url": "https://example.test", "authType": "key",
            "key": "new-key", "deployment": "model"
        ])
        let sections = method.form.visibleSections(drafts)
        XCTAssertEqual(sections.map(\.id), ["connection", "authentication", "deployment"])
        XCTAssertEqual(sections[0].fields.map(\.key), ["endpointType", "url"])
        XCTAssertEqual(sections[0].help, "URL help")
        XCTAssertEqual(sections[0].fields.first?.presentation, "segmented")
        XCTAssertEqual(sections[0].fields.last?.inputMode, "url")
    }

    func testAuthSwitchesRequireOnlySelectedInputs() throws {
        let method = try conditionalAuthMethod()
        var drafts = ["endpointType": "resource", "resource": "my-resource", "url": "stale-url",
                      "authType": "token", "token": "new-token", "key": "stale-key", "deployment": "model"]
        XCTAssertTrue(method.form.isValid(drafts))
        XCTAssertNil(method.form.submissionValues(drafts)["key"])
        XCTAssertNil(method.form.submissionValues(drafts)["url"])
        XCTAssertEqual(method.form.visibleSections(drafts)[0].help, "Resource help")
        drafts["token"] = " \n "
        XCTAssertFalse(method.form.isValid(drafts), "A hidden key cannot satisfy the selected token input")
        drafts["authType"] = "identity"
        XCTAssertTrue(method.form.isValid(drafts))
        XCTAssertEqual(method.form.visibleSections(drafts)[1].fields.map(\.key), ["authType"])
        XCTAssertEqual(method.form.visibleSections(drafts)[1].help, "Uses the workspace identity.")
        XCTAssertNil(method.form.submissionValues(drafts)["token"])
        drafts["resource"] = ""
        XCTAssertFalse(method.form.isValid(drafts), "A hidden URL cannot satisfy the selected resource input")
    }

    func testAuthRejectsUnknownAndEmptySelections() throws {
        let form = try conditionalAuthMethod().form
        let valid = ["url": "https://example.test", "key": "key", "deployment": "model"]
        for key in ["endpointType", "authType"] {
            for value in ["", "unknown"] {
                var drafts = valid
                drafts[key] = value
                XCTAssertFalse(form.isValid(drafts))
            }
        }
    }

    func testAuthStepRetainsFormSectionsAndOptionalFields() throws {
        let method = try conditionalAuthMethod()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(method)) as? [String: Any])
        json["method"] = method.id
        json["status"] = "needs_input"
        let state = try dec.decode(DaemonAuthState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(state.sections, method.sections)
        XCTAssertEqual(state.fields, method.fields)
        let old = try dec.decode(DaemonAuthState.self, from: Data(#"{"method":"login","status":"pending"}"#.utf8))
        XCTAssertTrue(old.sections.isEmpty)
        XCTAssertTrue(old.fields.isEmpty)
    }
}
