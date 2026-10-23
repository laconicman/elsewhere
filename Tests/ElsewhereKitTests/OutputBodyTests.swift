import Foundation
import Testing
@testable import ElsewhereKit

/// `OutputBody` is the fetch-report's body seam: what reaches stdout, and what
/// `--json` puts in `body` — testable without ArgumentParser.
@Suite("OutputBody — selection and the --json body")
struct OutputBodyTests {
    private func result(
        body: String = "<html><head><title>T</title></head><body><p>hi</p></body></html>",
        contentType: String? = "text/html"
    ) -> FetchResult {
        let url = URL(string: "https://example.com/x")!
        return FetchResult(
            requestURL: url, finalURL: url, status: 200, headers: [:],
            contentType: contentType, body: Data(body.utf8), truncated: false,
            elapsed: .seconds(1), exit: "direct", redirects: [])
    }

    @Test func headSelectsNoBodyInAnyMode() {
        for format in OutputFormat.allCases {
            #expect(OutputBody.select(
                result(), format: format, startIndex: 0, maxLength: 0,
                head: true) == .none)
        }
        // --head --json → body null.
        #expect(OutputBody.json(.none, of: result()) == nil)
    }

    @Test func rawSelectsTheResponseBytesUnpaged() {
        // Never decoded — a 1251 page's bytes would corrupt through String.
        #expect(OutputBody.select(
            result(), format: .raw, startIndex: 10, maxLength: 2,
            head: false) == .bytes(result().body))
        // --json still carries decoded text — JSON cannot carry bytes.
        #expect(OutputBody.json(.bytes(Data("x".utf8)), of: result()) == "x")
    }

    @Test func markdownSelectsRenderedPagedText() {
        guard case .text(let text) = OutputBody.select(
            result(), format: .markdown, startIndex: 0, maxLength: 0,
            head: false)
        else { Issue.record("expected .text"); return }
        #expect(text.contains("# T"))
        #expect(OutputBody.json(.text(text), of: result()) == text)
    }

    @Test func anUndecodableBodyIsTheBinaryNotice() {
        let png = FetchResult(
            requestURL: result().requestURL, finalURL: result().requestURL,
            status: 200, headers: [:], contentType: "image/png",
            body: Data([0x89, 0x50, 0x4E, 0x47]), truncated: false,
            elapsed: .seconds(1), exit: "direct", redirects: [])
        #expect(OutputBody.select(
            png, format: .markdown, startIndex: 0, maxLength: 0,
            head: false) == .undecodable)
        #expect(OutputBody.json(.undecodable, of: png) == nil)
    }
}
