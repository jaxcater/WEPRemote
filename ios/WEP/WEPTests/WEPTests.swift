import XCTest
@testable import WEP

final class WEPTests: XCTestCase {
    func testHostProfileDecodesPairingPayload() throws {
        let json = """
        {
          "name": "HOME-RIG",
          "tunnelUrl": "https://demo-wep.trycloudflare.com",
          "lanUrl": "http://192.168.1.50:8420",
          "token": "wep_123456",
          "version": "2.0.0"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HostProfile.self, from: json)
        XCTAssertEqual(decoded.name, "HOME-RIG")
        XCTAssertEqual(decoded.tunnelUrl, "https://demo-wep.trycloudflare.com")
        XCTAssertEqual(decoded.lanUrl, "http://192.168.1.50:8420")
        XCTAssertEqual(decoded.token, "wep_123456")
    }

    func testAiModelOptionSeparatesEfforts() throws {
        let json = """
        {
          "id": "gpt-6.1-sol",
          "displayName": "GPT-6.1 Sol",
          "engine": "codex",
          "baseModel": "gpt-6.1-sol",
          "defaultEffort": "medium",
          "supportedEfforts": ["low", "medium", "high", "xhigh", "max", "ultra"]
        }
        """.data(using: .utf8)!

        let model = try JSONDecoder().decode(AiModelOption.self, from: json)
        XCTAssertEqual(model.resolvedEngine, .codex)
        XCTAssertEqual(model.efforts.count, 6)
        XCTAssertEqual(model.defaultEffort, "medium")
    }

    func testSessionTurnDecodesDecisionAndQueuedState() throws {
        let json = """
        {
          "id": "turn-1",
          "engine": "antigravity",
          "prompt": "Plan refactor",
          "attachedFiles": [],
          "responseText": "Should I proceed with Option A?",
          "thinkingText": "",
          "status": "queued",
          "needsDecision": true,
          "decisionPrompt": "Approve Option A?",
          "durationSeconds": 1.2,
          "toolSteps": []
        }
        """.data(using: .utf8)!

        let turn = try JSONDecoder().decode(SessionTurn.self, from: json)
        XCTAssertTrue(turn.isQueued)
        XCTAssertFalse(turn.isTerminal)
        XCTAssertTrue(turn.requiresUserDecision)
        XCTAssertEqual(turn.decisionPrompt, "Approve Option A?")
    }

    func testAgentStartResponseDecodesQueuedFlag() throws {
        let json = """
        {
          "accepted": true,
          "sessionId": "sess-1",
          "turnId": "turn-2",
          "queued": true
        }
        """.data(using: .utf8)!

        let resp = try JSONDecoder().decode(AgentStartResponse.self, from: json)
        XCTAssertEqual(resp.accepted, true)
        XCTAssertEqual(resp.sessionId, "sess-1")
        XCTAssertEqual(resp.turnId, "turn-2")
        XCTAssertEqual(resp.queued, true)
    }

    func testDetectTurnNotificationsEmitsCompletionAndDecisionOnce() {
        let previous: [String: TurnStateSnapshot] = [
            "t-complete": TurnStateSnapshot(status: "running", needsDecision: false),
            "t-decision": TurnStateSnapshot(status: "running", needsDecision: false),
            "t-already-done": TurnStateSnapshot(status: "success", needsDecision: false)
        ]

        let updatedSession = SessionRecord(
            id: "s-1",
            engine: "antigravity",
            agyConversationId: nil,
            codexThreadId: nil,
            title: "Build Feature",
            workspacePath: "C:\\Repo",
            model: "gemini-4-hydrogen",
            effort: "high",
            mode: "auto",
            createdAt: nil,
            updatedAt: nil,
            isRunning: false,
            turns: [
                SessionTurn(
                    id: "t-complete",
                    engine: "antigravity",
                    model: "gemini-4-hydrogen",
                    effort: "high",
                    prompt: "Run tests",
                    attachedFiles: [],
                    responseText: "All tests passed.",
                    thinkingText: "",
                    status: "success",
                    needsDecision: false,
                    decisionPrompt: nil,
                    durationSeconds: 3.0,
                    usage: nil,
                    startedAt: nil,
                    toolSteps: []
                ),
                SessionTurn(
                    id: "t-decision",
                    engine: "antigravity",
                    model: "gemini-4-hydrogen",
                    effort: "high",
                    prompt: "Plan migration",
                    attachedFiles: [],
                    responseText: "Choose strategy A or B?",
                    thinkingText: "",
                    status: "success",
                    needsDecision: true,
                    decisionPrompt: "Choose strategy A or B?",
                    durationSeconds: 2.0,
                    usage: nil,
                    startedAt: nil,
                    toolSteps: []
                ),
                SessionTurn(
                    id: "t-already-done",
                    engine: "antigravity",
                    model: "gemini-4-hydrogen",
                    effort: "high",
                    prompt: "Old task",
                    attachedFiles: [],
                    responseText: "Done earlier",
                    thinkingText: "",
                    status: "success",
                    needsDecision: false,
                    decisionPrompt: nil,
                    durationSeconds: 1.0,
                    usage: nil,
                    startedAt: nil,
                    toolSteps: []
                )
            ]
        )

        let events = AppState.detectTurnNotifications(previous: previous, updated: [updatedSession])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].kind, .completed)
        XCTAssertEqual(events[0].turnId, "t-complete")
        XCTAssertEqual(events[1].kind, .decision)
        XCTAssertEqual(events[1].turnId, "t-decision")
    }
}
