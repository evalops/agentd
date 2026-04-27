import XCTest
@testable import agentd

final class SecretScrubberTests: XCTestCase {
    func testCleanText() {
        XCTAssertEqual(SecretScrubber.evaluate("hello world, no secrets here"), .clean)
    }

    func testAwsAccessKeyDropped() {
        if case .dropped(let reason) = SecretScrubber.evaluate("the key is AKIAIOSFODNN7EXAMPLE in env") {
            XCTAssertEqual(reason, "aws_access_key")
        } else {
            XCTFail("expected drop")
        }
    }

    func testGithubTokenDropped() {
        if case .dropped(let reason) = SecretScrubber.evaluate("export GH=ghp_abcdef0123456789ABCDEF0123456789abcd") {
            XCTAssertEqual(reason, "github_token")
        } else {
            XCTFail("expected drop")
        }
    }

    func testJwtDropped() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhYmMifQ.signaturepartlonger"
        if case .dropped(let reason) = SecretScrubber.evaluate("Authorization: Bearer \(jwt)") {
            XCTAssertEqual(reason, "jwt")
        } else {
            XCTFail("expected drop")
        }
    }

    func testPrivateKeyMarkerDropped() {
        if case .dropped(let reason) = SecretScrubber.evaluate("-----BEGIN OPENSSH PRIVATE KEY-----\nMIIE...") {
            XCTAssertEqual(reason, "ssh_private")
        } else {
            XCTFail("expected drop")
        }
    }

    func testPathPolicyDeniesSshAndAws() {
        let p = PathPolicy(deniedPrefixes: AgentConfig.defaultDeniedPathPrefixes)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(p.deny("\(home)/.ssh/id_ed25519"))
        XCTAssertTrue(p.deny("\(home)/.aws/credentials"))
        XCTAssertFalse(p.deny("\(home)/Documents/notes.md"))
    }
}
