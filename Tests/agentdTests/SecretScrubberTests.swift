// SPDX-License-Identifier: BUSL-1.1

import XCTest

@testable import agentd

final class SecretScrubberTests: XCTestCase {
  func testCleanText() {
    XCTAssertEqual(SecretScrubber.evaluate("hello world, no secrets here"), .clean)
  }

  func testAwsAccessKeyDropped() {
    assertDrops(
      "the key is \("AKIA" + String(repeating: "A", count: 16)) in env", reason: "aws_access_key")
  }

  func testGithubTokenDropped() {
    let token = "ghp_" + String(repeating: "A", count: 36)
    assertDrops("export GH=\(token)", reason: "github_token")
  }

  func testJwtDropped() {
    assertDrops("Authorization: Bearer \(Self.jwtFixture())", reason: "jwt")
  }

  func testPrivateKeyMarkerDropped() {
    assertDrops("-----BEGIN OPENSSH PRIVATE KEY-----\nMIIE...", reason: "ssh_private")
  }

  func testExpandedProviderPatternsDropped() {
    let fixtures: [(String, String)] = [
      (
        "github_fine_grained_token",
        ["github", "pat"].joined(separator: "_") + "_" + String(repeating: "A", count: 82)
      ),
      ("google_api_key", "AIza" + String(repeating: "A", count: 35)),
      ("npm_token", "npm_" + String(repeating: "A", count: 36)),
      (
        "sendgrid_key",
        "SG." + String(repeating: "A", count: 22) + "." + String(repeating: "B", count: 43)
      ),
      ("digitalocean_pat", "dop_v1_" + String(repeating: "a", count: 64)),
      ("azure_storage_key", "AccountKey=" + String(repeating: "A", count: 88)),
      ("mailgun_key", "key-" + String(repeating: "a", count: 32)),
      ("twilio_api_key", "SK" + String(repeating: "a", count: 32)),
      (
        "discord_bot_token",
        String(repeating: "A", count: 24) + "." + String(repeating: "B", count: 6) + "."
          + String(repeating: "C", count: 27)
      ),
      ("openai_key", "sk-proj-" + String(repeating: "A", count: 32)),
    ]

    for (reason, token) in fixtures {
      assertDrops("credential=\(token)", reason: reason)
    }
  }

  func testOpenAIKeyPatternAvoidsShortSkNoise() {
    XCTAssertEqual(SecretScrubber.evaluate("not a provider key: sk-demo"), .clean)
  }

  func testPathPolicyDeniesSshAndAws() {
    let p = PathPolicy(deniedPrefixes: AgentConfig.defaultDeniedPathPrefixes)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    XCTAssertTrue(p.deny("\(home)/.ssh/id_ed25519"))
    XCTAssertTrue(p.deny("\(home)/.aws/credentials"))
    XCTAssertFalse(p.deny("\(home)/Documents/notes.md"))
  }

  static func jwtFixture() -> String {
    "eyJ" + String(repeating: "a", count: 12)
      + ".eyJ" + String(repeating: "b", count: 12)
      + "." + String(repeating: "c", count: 16)
  }

  private func assertDrops(
    _ text: String, reason: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    if case .dropped(let actual) = SecretScrubber.evaluate(text) {
      XCTAssertEqual(actual, reason, file: file, line: line)
    } else {
      XCTFail("expected drop for \(reason)", file: file, line: line)
    }
  }
}
