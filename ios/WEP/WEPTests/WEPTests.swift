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
          "version": "1.0.0"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HostProfile.self, from: json)
        XCTAssertEqual(decoded.name, "HOME-RIG")
        XCTAssertEqual(decoded.tunnelUrl, "https://demo-wep.trycloudflare.com")
        XCTAssertEqual(decoded.lanUrl, "http://192.168.1.50:8420")
        XCTAssertEqual(decoded.token, "wep_123456")
    }

    func testExecutionModesHaveExpectedRawValues() {
        XCTAssertEqual(ExecutionMode.auto.rawValue, "auto")
        XCTAssertEqual(ExecutionMode.acceptEdits.rawValue, "accept-edits")
        XCTAssertEqual(ExecutionMode.plan.rawValue, "plan")
    }
}
