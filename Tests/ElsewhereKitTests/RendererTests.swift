import Foundation
import Testing
@testable import ElsewhereKit

/// HTML → Markdown, pinned by goldens over captured pages (`Fixtures/html/SOURCES.md`
/// lists their provenance) and by small unit cases for each contract rule. The
/// goldens are the renderer's own output — generated once with
/// `ELSEWHERE_WRITE_GOLDENS=1`, read by eye, frozen.
@Suite("Renderer — HTML to Markdown")
struct RendererTests {
    static func fixture(_ name: String, ext: String = "html") throws -> String {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: ext, subdirectory: "Fixtures/html"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func golden(_ name: String) throws -> String {
        try fixture(name, ext: "md")
    }

    /// The base relative links resolve against — each fixture renders against the
    /// URL it was captured from.
    static func render(
        _ fixture: String, _ page: String,
        format: OutputFormat = .markdown, contentType: String? = "text/html"
    ) throws -> String {
        try Renderer.render(
            Self.fixture(fixture), contentType: contentType,
            finalURL: #require(URL(string: page)), format: format)
    }

    // MARK: - Goldens (writeGoldens regenerates; everything else compares)

    @Test func constructsMatchMarkdownGolden() throws {
        #expect(try Self.render("constructs", "https://example.com/docs/page")
            == Self.golden("constructs"))
    }

    @Test func constructsMatchTextGolden() throws {
        #expect(try Self.render(
            "constructs", "https://example.com/docs/page", format: .text)
            == Self.golden("constructs-text"))
    }

    @Test func swiftLibxrayReadmeMatchesGolden() throws {
        #expect(try Self.render(
            "swift-libxray-readme", "https://github.com/laconicman/swift-libxray")
            == Self.golden("swift-libxray-readme"))
    }

    @Test func wikipediaIfconfigMatchesGolden() throws {
        #expect(try Self.render(
            "wikipedia-ifconfig", "https://en.wikipedia.org/wiki/Ifconfig")
            == Self.golden("wikipedia-ifconfig"))
    }

    @Test func appleDoccShellMatchesGolden() throws {
        let rendered = try Self.render(
            "apple-docc-shell", "https://developer.apple.com/documentation/swift")
        #expect(rendered == (try Self.golden("apple-docc-shell")))
        // The point of this fixture: external scripts + a near-empty shell.
        #expect(rendered.contains(Renderer.jsShellNote))
    }

    /// The goldens' provenance — `ELSEWHERE_WRITE_GOLDENS=1 swift test --filter
    /// writeRendererGoldens`; skipped otherwise.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ELSEWHERE_WRITE_GOLDENS"] == "1"))
    func writeRendererGoldens() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/html", directoryHint: .isDirectory)
        let cases: [(String, String)] = [
            ("constructs", try Self.render("constructs", "https://example.com/docs/page")),
            ("constructs-text", try Self.render(
                "constructs", "https://example.com/docs/page", format: .text)),
            ("swift-libxray-readme", try Self.render(
                "swift-libxray-readme", "https://github.com/laconicman/swift-libxray")),
            ("wikipedia-ifconfig", try Self.render(
                "wikipedia-ifconfig", "https://en.wikipedia.org/wiki/Ifconfig")),
            ("apple-docc-shell", try Self.render(
                "apple-docc-shell", "https://developer.apple.com/documentation/swift")),
        ]
        for (name, markdown) in cases {
            try Data(markdown.utf8).write(to: dir.appending(path: "\(name).md"))
        }
    }

    // MARK: - Format contract

    @Test func rawReturnsTheInput() {
        let html = "<html><body><p>x</p></body></html>"
        let url = URL(string: "https://example.com")!
        #expect(Renderer.render(html, contentType: "text/html",
                                finalURL: url, format: .raw) == html)
    }

    @Test func nonHTMLPassesThroughForEveryFormat() throws {
        let trace = try Self.fixture("trace", ext: "txt")
        let url = URL(string: "https://1.1.1.1/cdn-cgi/trace")!
        for format in OutputFormat.allCases {
            #expect(Renderer.render(trace, contentType: "text/plain",
                                    finalURL: url, format: format) == trace)
        }
        let json = #"{"a":1}"#
        for format in OutputFormat.allCases {
            #expect(Renderer.render(json, contentType: "application/json",
                                    finalURL: url, format: format) == json)
        }
    }

    @Test func missingContentTypeSniffsTheOpening() {
        let url = URL(string: "https://example.com")!
        let rendered = Renderer.render(
            "  <!DOCTYPE html><title>T</title><body><p>hi</p></body>",
            contentType: nil, finalURL: url, format: .markdown)
        #expect(rendered.hasPrefix("# T\n\nhi"))
        #expect(Renderer.render("plain text", contentType: nil,
                                finalURL: url, format: .markdown) == "plain text")
    }

    @Test func titleAndSourceFooterShape() {
        let rendered = Renderer.render(
            "<title>Page T</title><body><p>body</p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com/x")!, format: .markdown)
        #expect(rendered == "# Page T\n\nbody\n\nSource: https://example.com/x\n")
    }

    @Test func noTitleMeansNoHeadingLine() {
        let rendered = Renderer.render(
            "<body><p>body</p></body>", contentType: "text/html",
            finalURL: URL(string: "https://example.com/x")!, format: .markdown)
        #expect(rendered == "body\n\nSource: https://example.com/x\n")
    }

    // MARK: - Links, images, code

    @Test func relativeLinksResolveAgainstFinalURL() {
        let rendered = Renderer.render(
            #"<body><p><a href="rel/p">r</a> <a href="/root">s</a> <img src="i.png" alt="a"></p></body>"#,
            contentType: "text/html",
            finalURL: URL(string: "https://example.com/dir/page")!, format: .markdown)
        #expect(rendered.contains("[r](https://example.com/dir/rel/p)"))
        #expect(rendered.contains("[s](https://example.com/root)"))
        #expect(rendered.contains("![a](https://example.com/dir/i.png)"))
    }

    @Test func javascriptAndAnchorLinksDropTheirSyntax() {
        let rendered = Renderer.render(
            ##"<body><p><a href="javascript:x()">go</a> <a href="#frag">jump</a> <a href="https://e.com"></a></p></body>"##,
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("go jump\n")) // text stays, syntax and empty link go
    }

    @Test func nestedListsIndentTwoSpacesPerLevel() {
        let rendered = Renderer.render(
            "<body><ul><li>a<ul><li>b<ul><li>c</li></ul></li></ul></li></ul>"
                + "<ol><li>one</li><li>two</li></ol></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("- a\n  - b\n    - c"))
        #expect(rendered.contains("1. one\n2. two"))
    }

    @Test func tableEscapesPipesAndFlattensCells() {
        let rendered = Renderer.render(
            "<body><table><tr><th>A</th><th>B</th></tr>"
                + "<tr><td>x|y</td><td>m<br>n</td></tr></table></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("| A | B |\n|---|---|\n| x\\|y | m n |"))
    }

    @Test func tableWithoutHeaderUsesFirstRow() {
        let rendered = Renderer.render(
            "<body><table><tr><td>h1</td><td>h2</td></tr><tr><td>a</td><td>b</td></tr></table></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("| h1 | h2 |\n|---|---|\n| a | b |"))
    }

    @Test func fenceLanguageComesFromPreOrCodeClasses() {
        let url = URL(string: "https://example.com")!
        let preCode = Renderer.render(
            #"<body><pre><code class="language-swift">let x = 1</code></pre></body>"#,
            contentType: "text/html", finalURL: url, format: .markdown)
        #expect(preCode.contains("```swift\nlet x = 1\n```"))
        let preLang = Renderer.render(
            #"<body><pre class="lang-python"><code>pass</code></pre></body>"#,
            contentType: "text/html", finalURL: url, format: .markdown)
        #expect(preLang.contains("```python\npass\n```"))
        let none = Renderer.render(
            "<body><pre><code>raw</code></pre></body>",
            contentType: "text/html", finalURL: url, format: .markdown)
        #expect(none.contains("```\nraw\n```"))
    }

    @Test func inlineCodeWithABacktickGetsDoubleBackticks() {
        let rendered = Renderer.render(
            "<body><p><code>a`b</code></p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("``a`b``"))
    }

    // MARK: - The shell note and whitespace

    @Test func jsShellNoteOnOffAroundTheThreshold() {
        let url = URL(string: "https://example.com")!
        let shell = Renderer.render(
            #"<html><head><script src="app.js"></script></head><body><p>x</p></body></html>"#,
            contentType: "text/html", finalURL: url, format: .markdown)
        #expect(shell.contains(Renderer.jsShellNote))
        // No external script → no note even when the body is tiny.
        let quiet = Renderer.render(
            "<html><body><p>x</p></body></html>",
            contentType: "text/html", finalURL: url, format: .markdown)
        #expect(!quiet.contains(Renderer.jsShellNote))
        // A body past the threshold → no note even with an external script.
        let padded = String(repeating: "word ", count: 50)
        let full = Renderer.render(
            #"<html><head><script src="app.js"></script></head><body><p>"# + padded
                + "</p></body></html>",
            contentType: "text/html", finalURL: url, format: .markdown)
        #expect(!full.contains(Renderer.jsShellNote))
    }

    @Test func whitespaceCollapsesWithinAndBetweenBlocks() {
        let rendered = Renderer.render(
            "<body><p>one\n\n   two\t\tthree</p>\n\n\n\n<p>four</p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.hasPrefix("one two three\n\nfour\n"))
        #expect(rendered.hasSuffix("\n"))
        #expect(!rendered.hasSuffix("\n\n"))
    }

    @Test func blockStartMarkersAreEscaped() {
        let rendered = Renderer.render(
            "<body><p># not a heading</p><p>- not a list</p><p>1. not numbered</p><p>2026</p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("\\# not a heading"))
        #expect(rendered.contains("\\- not a list"))
        #expect(rendered.contains("1\\. not numbered"))
        // A bare number is not a list marker — and must not trip the index scan.
        #expect(rendered.contains("\n2026\n"))
    }

    // MARK: - text format

    @Test func textStripsMarkersButKeepsStructure() {
        let rendered = Renderer.render(
            #"<html><head><title>T</title></head><body><h1>Head</h1>"#
                + #"<p><strong>b</strong> <em>e</em> <code>c</code> "#
                + #"<a href="/x">link</a> <img src="i.png" alt="ALT"></p>"#
                + "<ul><li>item</li></ul></body></html>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .text)
        #expect(rendered.contains("T\n\nHead\n\nb e c link ALT\n\n- item"))
        #expect(!rendered.contains("[link]"))
        #expect(!rendered.contains("**"))
        #expect(!rendered.contains("`"))
        #expect(rendered.contains("Source: https://example.com"))
    }
}
