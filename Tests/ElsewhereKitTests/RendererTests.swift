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

    /// A page's non-web scheme stays content — the output never makes `file:`,
    /// `data:` or a share link actionable; http(s) and mailto still link.
    @Test func nonWebSchemeLinksRenderAsTheirText() {
        let rendered = Renderer.render(
            "<body><p><a href=\"file:///etc/passwd\">f</a> "
                + "<a href=\"data:text/plain,x\">d</a> "
                + "<a href=\"vless://00000000-0000-0000-0000-000000000000@h:443\">v</a> "
                + "<a href=\"https://e.com/p\">ok</a> "
                + "<a href=\"mailto:a@b.c\">m</a></p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("f d v"))
        #expect(!rendered.contains("file:"))
        #expect(!rendered.contains("data:"))
        #expect(!rendered.contains("vless:"))
        #expect(rendered.contains("[ok](https://e.com/p)"))
        #expect(rendered.contains("[m](mailto:a@b.c)"))
    }

    /// `[`/`]` in link text escape; a destination with parens takes the `<dest>`
    /// form; an href `URLComponents` cannot parse is text, not a link.
    @Test func linksEscapeBracketsAndOddHrefsAreNotLinks() {
        let rendered = Renderer.render(
            "<body><p><a href=\"/u\">a]b</a> <a href=\"/x(1)\">p</a> "
                + "<a href=\"java\tscript:bad()\">t</a></p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("[a\\]b](https://example.com/u)"))
        #expect(rendered.contains("[p](<https://example.com/x(1)>)"))
        // A tab in the scheme makes the href unparseable — text, never a link.
        #expect(rendered.contains(" t\n") || rendered.hasSuffix(" t"))
        #expect(!rendered.contains("[t]("))
    }

    /// A link wrapping block children can't inline-wrap them — the blocks stay
    /// and the destination survives as a link line of the `a`'s own text.
    @Test func aLinkWrappingBlocksKeepsItsDestination() {
        let rendered = Renderer.render(
            "<body><a href=\"/dest\"><div>Big block</div><p>more</p></a></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("Big block\n\nmore"))
        #expect(rendered.contains("[Big block more](https://example.com/dest)"))
    }

    /// `img` with a non-http(s) source renders its alt text alone.
    @Test func aNonHttpImageSourceRendersItsAlt() {
        let rendered = Renderer.render(
            "<body><p><img src=\"data:image/png;base64,xx\" alt=\"pixel\"> "
                + "<img src=\"/p.png\" alt=\"rel\"></p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("pixel"))
        #expect(!rendered.contains("data:"))
        #expect(rendered.contains("![rel](https://example.com/p.png)"))
    }

    /// A container whose children are text and inline elements without a wrapping
    /// `<p>` is ONE paragraph — the link survives and the words stay together
    /// (the layout-lines defect: they used to split into separate blocks).
    @Test func anInlineRunInAContainerIsOneParagraph() {
        let rendered = Renderer.render(
            #"<body><div>See <a href="/x">here</a> now</div></body>"#,
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("See [here](https://example.com/x) now"))
    }

    /// Inline runs and block children alternate correctly inside one container.
    @Test func inlineRunsAlternateWithBlockChildren() {
        let rendered = Renderer.render(
            "<body><div>text<p>para</p>tail <em>e</em></div></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("text\n\npara\n\ntail *e*"))
    }

    /// A whitespace-only inline element is the space between its siblings — the
    /// golden's `August1983` merge.
    @Test func elementEdgesKeepTheirWhitespace() {
        let rendered = Renderer.render(
            "<body><p>August<span>&nbsp;</span>1983</p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("August 1983"))
    }

    /// Boundary spaces inside a mixed element survive — the golden's
    /// `net-tools)on(` merge.
    @Test func boundarySpacesInsideElementsSurvive() {
        let rendered = Renderer.render(
            "<body><p><a href=\"/a\">net-tools</a><span> on </span>"
                + "<a href=\"/b\">SourceForge</a></p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains(") on ["))
    }

    /// Block-level children met in inline context still separate — a cell's two
    /// paragraphs are "alpha beta", not "alphabeta".
    @Test func blockChildrenInsideACellSeparate() {
        let rendered = Renderer.render(
            "<body><table><tr><td><p>alpha</p><p>beta</p></td></tr></table></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("alpha beta"))
    }

    /// The `Source:` footer follows the `--json` rule — a credentialled URL's
    /// userinfo never reaches stdout.
    @Test func theSourceFooterDropsUserinfo() {
        let rendered = Renderer.render(
            "<body><p>x</p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://user:secret@example.com/p")!,
            format: .markdown)
        #expect(rendered.contains("Source: https://example.com/p"))
        #expect(!rendered.contains("secret"))
    }

    /// SwiftSoup parses arbitrarily deep trees; the renderer caps DOM depth and
    /// the subtree past it renders as its collapsed text — no recursion, no
    /// crash, content kept.
    @Test func aDeepDomRendersWithoutCrashing() {
        let divNest = String(repeating: "<div>", count: 5_000) + "leaf"
        let rendered = Renderer.render(
            divNest, contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("leaf"))
        let emNest = String(repeating: "<em>", count: 5_000) + "inner"
        #expect(Renderer.render(
            emNest, contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
            .contains("inner"))
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

    /// `ol[start]` seeds the counter; `li[value]` overrides it and numbering
    /// continues from the emitted value.
    @Test func orderedListsHonourStartAndValue() {
        let rendered = Renderer.render(
            "<body><ol start=\"5\"><li>a</li><li>b</li></ol>"
                + "<ol><li value=\"9\">x</li><li>y</li></ol></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("5. a\n6. b"))
        #expect(rendered.contains("9. x\n10. y"))
    }

    /// Text around a nested list keeps document order: before → item line,
    /// nested items, after → a continuation paragraph at the text column after
    /// a blank line (no blank line and it joins the last nested item).
    @Test func itemTextAroundANestedListKeepsDocumentOrder() {
        let rendered = Renderer.render(
            "<body><ul><li>before<ul><li>nested</li></ul>after</li></ul></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("- before\n  - nested\n\n  after"))
    }

    /// The nested indent is the parent marker's width — a `10. ` item's
    /// children need four spaces, not two.
    @Test func nestedIndentIsTheParentMarkersWidth() {
        let rendered = Renderer.render(
            "<body><ol start=\"10\"><li>parent<ul><li>child</li></ul></li></ol></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("10. parent\n    - child"))
    }

    /// A non-list block child inside an `li` renders as its own block at the
    /// text column after a blank line — a `pre` keeps its lines, fenced.
    @Test func aListItemKeepsItsBlockChildren() {
        let rendered = Renderer.render(
            "<body><ul><li>item<pre>a\n  b</pre></li></ul></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("- item\n\n  ```\n  a\n    b\n  ```"))
    }

    /// A multi-paragraph item: the first block joins the bullet, the second is
    /// a blank-line-separated block at the text column.
    @Test func aMultiParagraphItemContinuesAtTheTextColumn() {
        let rendered = Renderer.render(
            "<body><ul><li><p>one</p><p>two</p></li></ul></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("- one\n\n  two"))
    }

    @Test func tableEscapesPipesAndFlattensCells() {
        let rendered = Renderer.render(
            "<body><table><tr><th>A</th><th>B</th></tr>"
                + "<tr><td>x|y</td><td>m<br>n</td></tr></table></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("| A | B |\n|---|---|\n| x\\|y | m n |"))
    }

    /// A narrow header pads to the widest row — the value column survives
    /// instead of vanishing into a 1-cell header (the Wikipedia infobox case).
    @Test func raggedRowsPadToTheWidest() {
        let rendered = Renderer.render(
            "<body><table><tr><th>Name</th></tr>"
                + "<tr><td>Release</td><td>1983</td></tr></table></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("| Name |  |"))
        #expect(rendered.contains("|---|---|"))
        #expect(rendered.contains("| Release | 1983 |"))
    }

    /// `colspan` fans a cell across its span — the value, then empty cells.
    @Test func colspanFansACellAcrossItsSpan() {
        let rendered = Renderer.render(
            "<body><table><tr><td colspan=\"2\">wide</td><td>x</td></tr>"
                + "<tr><td>a</td><td>b</td><td>c</td></tr></table></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("| wide |  | x |"))
        #expect(rendered.contains("| a | b | c |"))
    }

    /// `caption` is a bold line before the table; plain line in text mode.
    @Test func aCaptionLeadsTheTable() {
        let url = URL(string: "https://example.com")!
        let html = "<body><table><caption>Results</caption>"
            + "<tr><td>x</td></tr></table></body>"
        #expect(Renderer.render(html, contentType: "text/html", finalURL: url,
                                format: .markdown).contains("**Results**\n\n|"))
        #expect(Renderer.render(html, contentType: "text/html", finalURL: url,
                                format: .text).contains("Results\n\nx"))
    }

    /// A nested table's rows stay inside their cell — they never join the
    /// outer table's row list.
    @Test func nestedTableRowsStayInsideTheirCell() {
        let rendered = Renderer.render(
            "<body><table><tr><td>outer</td><td><table><tr><td>in</td></tr>"
                + "</table></td></tr></table></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        // One outer row only — the inner `tr` did not become a second row.
        #expect(rendered.contains("| outer | in |\n|---|---|\n"))
        #expect(!rendered.contains("\n| in |"))
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

    /// A fence must be longer than the longest backtick run inside the code —
    /// a triple inside a triple fence would end the block early.
    @Test func aCodeFenceOutlivesBacktickRuns() {
        let rendered = Renderer.render(
            "<body><pre><code>let a = ```bad```</code></pre></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("````\nlet a = ```bad```\n````"))
    }

    /// The same rule inline, plus CommonMark's space padding when the content
    /// begins or ends with a backtick.
    @Test func anInlineCodeSpanOutlivesBacktickRuns() {
        let rendered = Renderer.render(
            "<body><p><code>x``y</code> and <code>`tick`</code></p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("```x``y```"))
        #expect(rendered.contains("`` `tick` ``"))
    }

    /// `br` inside `pre` is a line break — the one construct promising verbatim
    /// whitespace keeps it.
    @Test func preKeepsBrLineBreaks() {
        let rendered = Renderer.render(
            "<body><pre>line1<br>line2</pre></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("line1\nline2"))
    }

    /// The `<pre>` convention forgives one newline right after the tag; every
    /// other edge newline is authored content.
    @Test func preKeepsItsOwnBlankLines() {
        let rendered = Renderer.render(
            "<body><pre>\n\ncode\n\n</pre></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("```\n\ncode\n\n```"))
    }

    /// An article's own `header` is content — only chrome *outside* the content
    /// root is removed.
    @Test func aHeaderInsideTheContentRootSurvives() {
        let rendered = Renderer.render(
            "<body><article><header><h1>Title</h1></header><p>body</p></article>"
                + "<nav>menu</nav></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("# Title"))
        #expect(!rendered.contains("menu"))
    }

    /// An empty first `main` falls through to the body — a decorative `main`
    /// must not blank the page.
    @Test func anEmptyMainFallsThroughToBody() {
        let rendered = Renderer.render(
            "<body><main></main><div>all the content</div></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("all the content"))
    }

    /// Inline `display:none` hides the same content `hidden` does.
    @Test func aDisplayNoneSpanIsDropped() {
        let rendered = Renderer.render(
            "<body><p>seen<span style=\"display:none\">hidden</span></p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("seen"))
        #expect(!rendered.contains("hidden"))
    }

    /// On a JavaScript shell `noscript` IS the content — it renders as blocks
    /// before the note. On a content page it drops.
    @Test func noscriptRendersOnAShellAndDropsOtherwise() {
        let shell = Renderer.render(
            "<html><head><script src=\"/app.js\"></script></head><body>"
                + "<noscript><p>needs JS</p></noscript><div id=\"app\"></div>"
                + "</body></html>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(shell.contains("needs JS"))
        #expect(shell.contains(Renderer.jsShellNote))
        let page = Renderer.render(
            "<body><main><p>real content here</p></main>"
                + "<noscript><p>needs JS</p></noscript></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(page.contains("real content here"))
        #expect(!page.contains("needs JS"))
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

    /// A `br` line inside a paragraph can carry a marker — every line is
    /// shielded, not just the first (the Devin finding: `intro<br>- item`).
    @Test func everyLineIsShieldedNotJustTheFirst() {
        let rendered = Renderer.render(
            "<body><div>intro<br>- item</div></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("intro\n\\- item"))
    }

    /// Every line-start shape that would open a block takes a backslash.
    @Test func everyBlockOpenerIsEscaped() {
        let rendered = Renderer.render(
            "<body><p>> quoted?</p><p>1) alt-numbered</p><p>```fence</p>"
                + "<p>~~~tilde</p><p>***</p><p>===</p><p>&lt;div</p>"
                + "<p>[x]: /y</p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("\\> quoted?"))
        #expect(rendered.contains("1\\) alt-numbered"))
        #expect(rendered.contains("\\```fence")) // a fence would swallow to EOF
        #expect(rendered.contains("\\~~~tilde"))
        #expect(rendered.contains("\\***"))
        #expect(rendered.contains("\\==="))
        #expect(rendered.contains("\\<div"))
        #expect(rendered.contains("\\[x]: /y")) // a link def renders invisibly
    }

    /// A legit leading `[text](url)` is not a link reference definition — the
    /// link keeps its syntax, no backslash.
    @Test func aLeadingLinkIsNotEscaped() {
        let rendered = Renderer.render(
            "<body><p><a href=\"/u\">link</a> first</p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.hasPrefix("[link](https://example.com/u) first"))
        #expect(!rendered.contains("\\["))
    }

    /// List-item text is shielded too — `- - item` would nest a real list.
    @Test func itemTextIsShieldedPerLine() {
        let rendered = Renderer.render(
            "<body><ul><li>- item</li></ul></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .markdown)
        #expect(rendered.contains("- \\- item"))
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

    /// `text` keeps block structure but every Markdown delimiter is gone: `> `,
    /// pipes, `---`, emphasis underscores.
    @Test func textHasNoMarkdownDelimiters() {
        let rendered = Renderer.render(
            "<body><blockquote><p>quoted</p></blockquote>"
                + "<table><tr><th>a</th><th>b</th></tr>"
                + "<tr><td>1</td><td>2</td></tr></table>"
                + "<hr><p>end</p></body>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .text)
        #expect(rendered.hasPrefix("quoted")) // no title → the body leads
        #expect(!rendered.contains("> "))
        #expect(rendered.contains("a  b")) // a row per line, two-space cells
        #expect(rendered.contains("1  2"))
        #expect(!rendered.contains("|"))   // no pipes, no separator row
        #expect(!rendered.contains("---")) // the rule drops
        #expect(rendered.contains("end"))
    }

    /// The JS-shell note has no emphasis markers in `text`.
    @Test func textShellNoteDropsTheEmphasis() {
        let rendered = Renderer.render(
            "<html><head><script src=\"/app.js\"></script></head>"
                + "<body><div id=\"root\"></div></body></html>",
            contentType: "text/html",
            finalURL: URL(string: "https://example.com")!, format: .text)
        #expect(rendered.contains(Renderer.jsShellNotePlain))
        #expect(!rendered.contains("_Note"))
    }
}
