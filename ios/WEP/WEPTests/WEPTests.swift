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
}
