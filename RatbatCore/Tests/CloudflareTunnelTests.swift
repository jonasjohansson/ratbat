import XCTest
@testable import RatbatCore

/// Unit tests for `CloudflareTunnel`.
///
/// Deliberately does NOT spawn actual `cloudflared` subprocesses — that's
/// flaky in CI (network, binary availability, timing) and covered by the
/// manual verification step in the task plan. What we CAN test cheaply:
///
/// - Initial state matches the documented idle contract.
/// - The `https://*.trycloudflare.com` URL regex extracts URLs from
///   real-world cloudflared output lines and rejects look-alikes.
/// - The YAML line-scan for `~/.cloudflared/config.yml` pulls the first
///   `hostname:` value out of a handful of shapes the cloudflared docs
///   show (top-level, inside `ingress:`, quoted, with a list dash,
///   trailing comment).
final class CloudflareTunnelTests: XCTestCase {

    @MainActor
    func testInitialStateIsIdle() {
        let tunnel = CloudflareTunnel()
        XCTAssertFalse(tunnel.isRunning)
        XCTAssertNil(tunnel.publicURL)
        XCTAssertNil(tunnel.error)
        XCTAssertEqual(tunnel.mode, .idle)
    }

    // MARK: - URL extraction

    func testExtractPublicURLFromBannerLine() {
        // Shape cloudflared actually prints — URL embedded in a box-drawn
        // banner surrounded by pipes and whitespace.
        let line = "|  https://purple-mouse-47.trycloudflare.com                      |"
        let url = CloudflareTunnel.extractPublicURL(from: line)
        XCTAssertEqual(url?.absoluteString, "https://purple-mouse-47.trycloudflare.com")
    }

    func testExtractPublicURLFromLogLine() {
        // Some cloudflared versions log it as a structured log entry.
        let line = "2026-04-16T10:00:00Z INF Your quick tunnel has been created! Visit it at: https://foo-bar-baz.trycloudflare.com"
        let url = CloudflareTunnel.extractPublicURL(from: line)
        XCTAssertEqual(url?.absoluteString, "https://foo-bar-baz.trycloudflare.com")
    }

    func testExtractPublicURLRejectsNonMatching() {
        // Other https URLs must not be picked up — we're specifically
        // looking for the trycloudflare.com domain.
        XCTAssertNil(CloudflareTunnel.extractPublicURL(
            from: "connecting to https://region2.argotunnel.com"
        ))
        XCTAssertNil(CloudflareTunnel.extractPublicURL(
            from: "no URL on this line at all"
        ))
    }

    // MARK: - config.yml hostname scan

    func testHostnameExtractionFromIngressStyleConfig() {
        let yaml = """
        tunnel: 12345
        credentials-file: /Users/jonas/.cloudflared/12345.json

        ingress:
          - hostname: radio.jonasjohansson.se
            service: http://localhost:18000
          - service: http_status:404
        """
        let url = CloudflareTunnel.firstHostnameURL(in: yaml)
        XCTAssertEqual(url?.absoluteString, "https://radio.jonasjohansson.se")
    }

    func testHostnameExtractionFromQuotedValue() {
        let yaml = """
        ingress:
          - hostname: "radio.example.com"
            service: http://localhost:18000
        """
        let url = CloudflareTunnel.firstHostnameURL(in: yaml)
        XCTAssertEqual(url?.absoluteString, "https://radio.example.com")
    }

    func testHostnameExtractionWithTrailingComment() {
        let yaml = """
        ingress:
          - hostname: radio.example.com # primary
            service: http://localhost:18000
        """
        let url = CloudflareTunnel.firstHostnameURL(in: yaml)
        XCTAssertEqual(url?.absoluteString, "https://radio.example.com")
    }

    func testHostnameExtractionReturnsNilWhenMissing() {
        let yaml = """
        tunnel: 12345
        credentials-file: /Users/jonas/.cloudflared/12345.json
        """
        XCTAssertNil(CloudflareTunnel.firstHostnameURL(in: yaml))
    }

    func testHostnameExtractionPicksFirstOfMany() {
        // We only promise the FIRST hostname — multi-hostname configs
        // can't be displayed meaningfully in a single-line caption
        // anyway, and for the common case (one ingress rule) this is
        // the right answer.
        let yaml = """
        ingress:
          - hostname: radio.example.com
            service: http://localhost:18000
          - hostname: other.example.com
            service: http://localhost:19000
        """
        let url = CloudflareTunnel.firstHostnameURL(in: yaml)
        XCTAssertEqual(url?.absoluteString, "https://radio.example.com")
    }
}
