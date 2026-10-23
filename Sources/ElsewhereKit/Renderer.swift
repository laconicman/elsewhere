public import Foundation // URL is public API
import SwiftSoup // the parser — never in the public surface (rule 1)

/// HTML → Markdown (§3.7, §5.6). A walk over SwiftSoup's DOM; the plumbing lives
/// in one file. What lands on stdout:
///
///     # <title>          (only when the document carries one)
///
///     <markdown body>
///
///     Source: <finalURL>
///
/// Non-HTML text — `text/plain`, JSON, a `cdn-cgi/trace` body — passes through
/// untouched for every format: no title line, no footer, byte-exact.
///
/// Escaping stays minimal on purpose: agents read raw Markdown, and over-escaping
/// hurts readability more than the occasional literal `#` helps a stray renderer —
/// only a text node that would otherwise open a block, and `|` in table cells.
public enum Renderer {
    /// Under this rendered body length a shell's markup is a symptom, not content.
    static let jsShellThreshold = 200
    static let jsShellNote =
        "_Note: this page appears to be rendered by JavaScript; "
        + "the HTML shell carried little content._"
    /// The same note for `text` — no emphasis markers in plain text.
    static let jsShellNotePlain =
        "Note: this page appears to be rendered by JavaScript; "
        + "the HTML shell carried little content."

    /// The schemes an emitted link may carry — a fetched page can contain
    /// someone's share link as content; the Markdown output never makes a
    /// non-web scheme actionable (Design).
    static let linkableSchemes: Set<String> = ["http", "https", "mailto"]
    /// Images only ride http(s) — any other scheme renders as the alt text.
    static let imageSchemes: Set<String> = ["http", "https"]

    /// DOM nesting the renderer follows. SwiftSoup parses arbitrarily deep
    /// trees (a hostile page can nest to stack-overflow depth); past this the
    /// subtree renders as its collapsed text — iterative, no recursion.
    static let maxDepth = 64

    /// - Parameters:
    ///   - text: the decoded body (`TextDecoder` decides text vs binary earlier).
    ///   - contentType: the response's Content-Type, if any.
    ///   - finalURL: the document's own URL — the base relative links resolve against.
    ///   - format: `raw` and every non-HTML body pass through unchanged.
    public static func render(
        _ text: String, contentType: String?, finalURL: URL, format: OutputFormat
    ) -> String {
        guard format != .raw else { return text }
        guard looksLikeHTML(text, contentType: contentType) else { return text }

        guard let document = try? SwiftSoup.parse(text, finalURL.absoluteString) else {
            return text // unparseable HTML is just text
        }

        // The shell check counts before the elements go.
        let hadExternalScripts = ((try? document.select("script[src]"))?.count ?? 0) > 0

        // `noscript` is not chrome — on a JavaScript shell it carries the page's
        // only useful content. It comes out before anything else and is
        // re-rendered as blocks when the shell note fires; otherwise it drops.
        let noscripts = (try? document.select("noscript")) ?? Elements()
        _ = try? noscripts.remove()

        // Always-hidden or machine-only nodes die wherever they live — inline
        // `display:none` hides the same content `hidden`/`aria-hidden` does.
        // `*=` already matches case-insensitively (SwiftSoup lowercases both
        // sides); no CSS4 `i` flag exists in its parser.
        if let junk = try? document.select(
            "script, style, svg, iframe, template, [hidden], [aria-hidden=true], "
                + "[style*=display:none], [style*=display: none]")
        { _ = try? junk.remove() }

        let markdown = format == .markdown

        // The root is the first semantic candidate that yields blocks — an empty
        // or decorative `main` falls through rather than blanking the page.
        var content: [String] = []
        var semanticRoot: Element?
        for selector in ["main", "article", "[role=main]"] where semanticRoot == nil {
            for candidate in (try? document.select(selector)) ?? Elements() {
                let rendered = blocks(of: candidate, markdown: markdown, depth: 0)
                if !rendered.isEmpty {
                    semanticRoot = candidate
                    content = rendered
                    break
                }
            }
        }

        if let root = semanticRoot {
            // Page chrome dies only outside the content root — an article's own
            // `header`/`aside` is content, not chrome.
            if let chrome = try? document.select("nav, footer, header, aside, form") {
                for element in chrome where !isInside(element, root) {
                    _ = try? element.remove()
                }
            }
        } else {
            // No semantic region — page chrome goes everywhere, then the body
            // renders.
            if let chrome = try? document.select("nav, footer, header, aside, form") {
                _ = try? chrome.remove()
            }
            content = blocks(
                of: document.body() ?? document, markdown: markdown, depth: 0)
        }

        var body = content.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if hadExternalScripts, body.count < jsShellThreshold {
            let fallback = noscripts
                .flatMap { blocks(of: $0, markdown: markdown, depth: 0) }
                .joined(separator: "\n\n")
            if !fallback.isEmpty {
                body = body.isEmpty ? fallback : body + "\n\n" + fallback
            }
            let note = markdown ? jsShellNote : jsShellNotePlain
            body = body.isEmpty ? note : body + "\n\n" + note
        }

        var out: [String] = []
        let title = ((try? document.title()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { out.append(markdown ? "# \(title)" : title) }
        if !body.isEmpty { out.append(body) }
        // Same rule as --json: a credentialled URL's userinfo never reaches stdout.
        out.append("Source: \(Redactor.redact(url: finalURL))")
        return out.joined(separator: "\n\n") + "\n"
    }

    /// Is `element` a strict descendant of `root`? Chrome scoping needs ancestry,
    /// not containment — the root itself doesn't count.
    private static func isInside(_ element: Element, _ root: Element) -> Bool {
        var node = element.parent()
        while let parent = node {
            if parent === root { return true }
            node = parent.parent()
        }
        return false
    }

    /// HTML when the type says so, or when the body opens like a document and the
    /// type says nothing.
    static func looksLikeHTML(_ text: String, contentType: String?) -> Bool {
        if let mediaType = contentType?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        {
            return mediaType == "text/html" || mediaType == "application/xhtml+xml"
        }
        let opening = text.drop(while: \.isWhitespace).prefix(15).lowercased()
        return opening.hasPrefix("<!doctype html") || opening.hasPrefix("<html")
    }
}

extension Renderer {
    /// Elements that can open a block — `block()` handles these. Everything else
    /// (text nodes, `a`/`em`/`span`/…, `br`, `img`) is inline content and joins the
    /// paragraph around it. `td`/`th`/`tr` are listed for completeness; `table()`
    /// reaches them first.
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "caption", "dd",
        "details", "dialog", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li",
        "main", "menu", "nav", "ol", "p", "pre", "section", "summary", "table",
        "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
    ]

    /// True when `element` opens a block — its tag is listed, or it carries a
    /// block-level descendant: an unlisted element *wrapping* block children is a
    /// container, not inline text (GitHub's `<markdown-accessiblity-table>` wraps a
    /// `table`; flattening it into a paragraph would lose the table). Past
    /// `maxDepth` everything is inline — the subtree becomes collapsed text.
    private static func isBlock(_ element: Element, depth: Int) -> Bool {
        guard depth < maxDepth else { return false }
        if blockTags.contains(element.tagName().lowercased()) { return true }
        return element.getChildNodes().contains { node in
            guard let child = node as? Element else { return false }
            return isBlock(child, depth: depth + 1)
        }
    }

    /// The block children of `element`, each a string that is one block. A maximal
    /// run of inline nodes renders as ONE paragraph — `<div>See <a>here</a> now</div>`
    /// is "See [here](…) now", not three blocks. (Before this grouping an inline
    /// element took `block()`'s default path and lost its link/emphasis entirely.)
    private static func blocks(of element: Element, markdown: Bool, depth: Int) -> [String] {
        var blocks: [String] = []
        var run: [Node] = []
        func flushRun() {
            let text = escapeLineStarts(
                trimBlock(run.map { inline($0, markdown: markdown, depth: depth + 1) }
                    .joined()),
                markdown: markdown)
            if !text.isEmpty { blocks.append(text) }
            run = []
        }
        for node in element.getChildNodes() {
            if let child = node as? Element, isBlock(child, depth: depth + 1) {
                flushRun()
                blocks += block(child, markdown: markdown, depth: depth + 1)
            } else {
                run.append(node)
            }
        }
        flushRun()
        return blocks
    }

    /// One element as blocks — the element-name switch is the whole contract.
    private static func block(_ element: Element, markdown: Bool, depth: Int) -> [String] {
        switch element.tagName().lowercased() {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(element.tagName().dropFirst()) ?? 1
            let text = trimBlock(inline(element, markdown: markdown, depth: depth))
            guard !text.isEmpty else { return [] }
            return [markdown ? String(repeating: "#", count: level) + " " + text : text]
        case "p", "figcaption", "address", "caption", "dt", "dd", "summary", "legend":
            let text = escapeLineStarts(
                trimBlock(inline(element, markdown: markdown, depth: depth)),
                markdown: markdown)
            return text.isEmpty ? [] : [text]
        case "ul", "ol":
            return listItems(element, ordered: element.tagName() == "ol",
                             indent: "", markdown: markdown, depth: depth)
        case "li":
            return ["- " + trimBlock(inline(element, markdown: markdown, depth: depth))]
        case "blockquote":
            let inner = blocks(of: element, markdown: markdown, depth: depth)
            // `> ` is a Markdown delimiter — plain text keeps the paragraphs bare.
            guard markdown else { return inner }
            let joined = inner.joined(separator: "\n\n")
            guard !joined.isEmpty else { return [] }
            return [joined.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")]
        case "pre":
            return [preBlock(element, markdown: markdown, depth: depth)]
        case "table":
            return table(element, markdown: markdown, depth: depth)
        case "hr":
            // `---` is a Markdown delimiter — a rule just separates two blocks.
            return markdown ? ["---"] : []
        case "a":
            // A link wrapping blocks can't inline-wrap them — keep the blocks,
            // then carry the destination as a link line of the `a`'s own text
            // (80 chars, or "link" when empty).
            var out = blocks(of: element, markdown: markdown, depth: depth)
            let href = ((try? element.attr("href")) ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard markdown, !href.isEmpty, !href.hasPrefix("#"),
                !href.lowercased().hasPrefix("javascript:"),
                Self.isLinkable(href, schemes: Self.linkableSchemes)
            else { return out }
            let text = trimBlock(inlineChildren(element, markdown: false,
                                                depth: depth))
                .replacingOccurrences(of: "\n", with: " ")
            let label = escapeBrackets(
                text.isEmpty ? "link" : String(text.prefix(80)))
            let absolute = (try? element.absUrl("href")) ?? href
            out.append(linkMarkdown(label, href: absolute))
            return out
        // No `br`/`img` arms: both are inline tags, so `blocks(of:)` routes them
        // into a paragraph's inline run — they never reach `block()`.
        default:
            // A container (div, section, main, article, figure, details, dl, …) or an
            // unknown element: blocks inside become their own blocks, inline content
            // a paragraph.
            let children = blocks(of: element, markdown: markdown, depth: depth)
            if !children.isEmpty { return children }
            let text = escapeLineStarts(
                trimBlock(inline(element, markdown: markdown, depth: depth)),
                markdown: markdown)
            return text.isEmpty ? [] : [text]
        }
    }

    /// `ul`/`ol` items — the whole list is one block of lines. A nested list
    /// indents to its parent item's text column, the marker's width (`- ` is 2,
    /// `10. ` is 4 — Markdown reads children by that column, not a fixed two).
    /// A non-list block child inside an `li` (`pre`, `table`, `blockquote`,
    /// headings, a second `p`) renders as its own block at the text column
    /// after a blank line; text after a nested list is a continuation paragraph
    /// the same way — the blank line keeps it off the last nested item.
    private static func listItems(
        _ list: Element, ordered: Bool, indent: String, markdown: Bool, depth: Int
    ) -> [String] {
        var lines: [String] = []
        // ol[start] seeds the counter; numbering continues from the emitted value.
        var number = ordered
            ? ((try? list.attr("start"))
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1)
            : 1
        for child in list.children() where child.tagName() == "li" {
            if ordered,
                let value = (try? child.attr("value"))
                    .flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
            { number = value } // li[value] overrides; the next item counts on
            let bullet = ordered ? "\(number). " : "- "
            number += 1
            let column = indent + String(repeating: " ", count: bullet.count)

            // Every line after the first continues at the item's text column.
            func indentLines(_ text: String) -> String {
                text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { column + $0 }.joined(separator: "\n")
            }

            // Children in document order: an `li` is text runs interleaved with
            // nested lists and block children — each plays a different part.
            enum Segment { case text(String); case list(String); case block([String]) }
            var segments: [Segment] = []
            var buffer = ""
            for node in child.getChildNodes() {
                guard let element = node as? Element else {
                    if let text = node as? TextNode {
                        buffer += collapse(text.text())
                    }
                    continue
                }
                let tag = element.tagName().lowercased()
                if (tag == "ul" || tag == "ol"), depth + 2 < maxDepth {
                    if !buffer.isEmpty {
                        segments.append(.text(buffer))
                        buffer = ""
                    }
                    segments.append(.list(listItems(
                        element, ordered: tag == "ol", indent: column,
                        markdown: markdown, depth: depth + 2).joined()))
                } else if isBlock(element, depth: depth + 2) {
                    if !buffer.isEmpty {
                        segments.append(.text(buffer))
                        buffer = ""
                    }
                    segments.append(.block(block(element, markdown: markdown,
                                                 depth: depth + 2)))
                } else {
                    buffer += inline(element, markdown: markdown,
                                     depth: depth + 2)
                }
            }
            if !buffer.isEmpty { segments.append(.text(buffer)) }

            var bulletUsed = false
            for segment in segments {
                switch segment {
                case .text(let raw):
                    // Item text is shielded per line too — a continuation can
                    // carry a marker.
                    let text = escapeLineStarts(trimBlock(raw), markdown: markdown)
                    if text.isEmpty { continue }
                    if bulletUsed {
                        lines.append("")
                        lines.append(indentLines(text))
                    } else {
                        var itemLines = text.split(
                            separator: "\n", omittingEmptySubsequences: false)
                            .map(String.init)
                        if let first = itemLines.first {
                            lines.append(indent + bullet + first)
                            itemLines.removeFirst()
                        }
                        lines += itemLines.map { column + $0 }
                        bulletUsed = true
                    }
                case .list(let nested):
                    if nested.isEmpty { continue }
                    if !bulletUsed {
                        lines.append(indent + bullet)
                        bulletUsed = true
                    }
                    lines.append(nested)
                case .block(let children):
                    var pending = children.filter { !$0.isEmpty }
                    if !bulletUsed {
                        // A one-line block joins the bullet; multi-line content
                        // stands alone, indented, after a blank line.
                        if let first = pending.first, !first.contains("\n") {
                            lines.append(indent + bullet + first)
                            pending.removeFirst()
                        } else {
                            lines.append(indent + bullet)
                        }
                        bulletUsed = true
                    }
                    for childBlock in pending {
                        lines.append("")
                        lines.append(indentLines(childBlock))
                    }
                }
            }
            if !bulletUsed {
                lines.append(indent + bullet) // an empty li is a bare bullet
            }
        }
        return lines.isEmpty ? [] : [lines.joined(separator: "\n")]
    }

    /// Fenced code: ` ```language `, content verbatim, ` ``` `. The language comes
    /// from `language-*`/`lang-*` on the `pre` or a `code` child; `text` format
    /// drops the fences, keeping the code as a plain block.
    private static func preBlock(_ pre: Element, markdown: Bool, depth: Int) -> String {
        var language = ""
        for candidate in [pre] + (pre.children().filter { $0.tagName() == "code" }) {
            if language.isEmpty, let names = try? candidate.classNames() {
                language = names.sorted()
                    .first { $0.hasPrefix("language-") || $0.hasPrefix("lang-") }
                    .map { name in
                        name.hasPrefix("language-")
                            ? String(name.dropFirst("language-".count))
                            : String(name.dropFirst("lang-".count))
                    } ?? ""
            }
        }
        // The HTML convention forgives ONE newline right after <pre>; every
        // other edge newline is authored content and survives.
        var code = wholeText(pre, depth: depth + 1)
        if code.hasPrefix("\n") { code.removeFirst() }
        if code.hasSuffix("\n") { code.removeLast() }
        // The fence must outlive the longest backtick run inside the code
        // (CommonMark 4.5 — a triple inside a triple would end the block early).
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(code) + 1))
        return markdown ? "\(fence)\(language)\n\(code)\n\(fence)" : code
    }

    /// Does `href` name a destination the output may make actionable? A relative
    /// reference has no scheme — it resolves against the page and is fine; an
    /// explicit scheme outside the allowlist renders as text alone. An href
    /// `URLComponents` cannot parse is not a link either — the "relative" guess
    /// is optimistic for a malformed destination.
    static func isLinkable(_ href: String, schemes: Set<String>) -> Bool {
        guard !href.isEmpty, let components = URLComponents(string: href)
        else { return false }
        guard let scheme = components.scheme?.lowercased() else { return true }
        return schemes.contains(scheme)
    }

    /// `[label](dest)` with `<dest>` form when the destination carries spaces
    /// or parens — either would break the syntax it lives inside. Brackets in
    /// the label escape at the text node (`escapeBrackets`), so generated
    /// markup — `![alt](src)` inside a link is legal CommonMark — survives.
    private static func linkMarkdown(_ label: String, href: String) -> String {
        let dest = href.contains(" ") || href.contains("(") || href.contains(")")
            ? "<\(href)>" : href
        return "[\(label)](\(dest))"
    }

    /// `[`/`]` in text destined for a link label escape; the label is the only
    /// context where a bare bracket opens markup the author never wrote.
    private static func escapeBrackets(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// The longest run of `` ` `` in `text` — a delimiter must be one longer.
    private static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0
        var run = 0
        for character in text {
            if character == "`" { run += 1; longest = max(longest, run) }
            else { run = 0 }
        }
        return longest
    }

    /// Every descendant text node verbatim — `pre` content keeps its whitespace.
    private static func wholeText(_ element: Element, depth: Int) -> String {
        guard depth < maxDepth else { return subtreeText(element, whole: true) }
        return element.getChildNodes().map { node in
            if let text = node as? TextNode { return text.getWholeText() }
            if let child = node as? Element {
                // The one construct promising verbatim whitespace keeps br.
                if child.tagName().lowercased() == "br" { return "\n" }
                return wholeText(child, depth: depth + 1)
            }
            return ""
        }.joined()
    }

    /// A subtree's text gathered iteratively — the `maxDepth` escape hatch: no
    /// recursion, content still surfaces. `whole` keeps whitespace verbatim
    /// (`pre`); otherwise whitespace collapses and `br` stays a newline, as in
    /// `inline`.
    private static func subtreeText(_ element: Element, whole: Bool) -> String {
        var parts: [String] = []
        var stack: [Node] = element.getChildNodes().reversed()
        while let node = stack.popLast() {
            if let text = node as? TextNode {
                parts.append(whole ? text.getWholeText() : text.text())
            } else if let child = node as? Element {
                if child.tagName().lowercased() == "br" {
                    parts.append("\n")
                    continue
                }
                stack.append(contentsOf: child.getChildNodes().reversed())
            }
        }
        let joined = parts.joined()
        return whole ? joined : collapseLines(joined)
    }

    /// GFM table: the first `tr` carrying a `th` is the header — else the first
    /// row — then a `|---|` separator and the body rows. Rows come from the
    /// table's own `thead`/`tbody`/`tfoot`/`tr` children, so a nested table keeps
    /// its rows. `colspan` fans a cell into that many cells (the value, then
    /// empties); `rowspan` is ignored — a spanning cell appears once, on its own
    /// row. Every row pads with empty cells to the widest, so a narrow header
    /// never drops a column. `caption` is a bold line before the table (plain
    /// in text mode). Cells flatten inline, `|` is escaped, newlines collapse.
    private static func table(_ table: Element, markdown: Bool, depth: Int) -> [String] {
        var rows: [Element] = []
        var caption = ""
        for child in table.children() {
            switch child.tagName().lowercased() {
            case "caption":
                caption = trimBlock(
                    inline(child, markdown: markdown, depth: depth + 1))
            case "tr":
                rows.append(child)
            case "thead", "tbody", "tfoot":
                rows += child.children().filter { $0.tagName().lowercased() == "tr" }
            default: break
            }
        }
        guard !rows.isEmpty else { return [] }
        func cells(_ row: Element) -> [String] {
            row.children().flatMap { cell -> [String] in
                guard ["td", "th"].contains(cell.tagName().lowercased())
                else { return [] }
                let text = trimBlock(
                    inline(cell, markdown: markdown, depth: depth + 2))
                    .replacingOccurrences(of: "\n", with: " ")
                let span = (try? cell.attr("colspan"))
                    .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
                return [text] + Array(repeating: "", count: max(0, span - 1))
            }
        }
        var grid = rows.map(cells)
        let width = grid.map(\.count).max() ?? 0
        guard width > 0 else { return [] }
        for index in grid.indices where grid[index].count < width {
            grid[index] += Array(repeating: "", count: width - grid[index].count)
        }
        let title = caption.isEmpty ? [] : [markdown ? "**\(caption)**" : caption]
        if !markdown {
            // Plain text has no pipes: one line per row, two spaces between
            // cells. An all-empty padded row joins to whitespace, not "" —
            // test the cells, not the join.
            let lines = grid.compactMap { row -> String? in
                guard row.contains(where: { !$0.isEmpty }) else { return nil }
                return row.joined(separator: "  ")
            }
            return title + (lines.isEmpty ? [] : [lines.joined(separator: "\n")])
        }
        func gfm(_ row: [String]) -> String {
            "| " + row
                .map { $0.replacingOccurrences(of: "|", with: "\\|") }
                .joined(separator: " | ") + " |"
        }
        let headerIndex = rows.firstIndex { row in
            row.children().contains { $0.tagName().lowercased() == "th" }
        } ?? 0
        var lines = [gfm(grid[headerIndex])]
        lines.append("|" + String(repeating: "---|", count: width))
        for (index, row) in grid.enumerated() where index != headerIndex {
            if row.contains(where: { !$0.isEmpty }) { lines.append(gfm(row)) }
        }
        return title + [lines.joined(separator: "\n")]
    }

    /// Everything inside one element as inline Markdown. Text nodes collapse —
    /// never trim — so a sibling keeps its boundary spaces; the edges trim at the
    /// block level. Past `maxDepth` the subtree is its collapsed text.
    /// `inLinkLabel` escapes `[`/`]` in text only — an `a`'s children are a link
    /// label, and a bare bracket there would close it early.
    private static func inline(
        _ node: Node, markdown: Bool, depth: Int, inLinkLabel: Bool = false
    ) -> String {
        if let text = node as? TextNode {
            let collapsed = collapse(text.text())
            return inLinkLabel ? escapeBrackets(collapsed) : collapsed
        }
        guard let element = node as? Element else { return "" }
        guard depth < maxDepth else { return subtreeText(element, whole: false) }
        switch element.tagName().lowercased() {
        case "br": return "\n"
        case "code":
            // inLinkLabel deliberately not forwarded: code spans bind tighter
            // than the brackets in link text (CommonMark 6.1 vs 6.2), so a
            // bracket inside a code span in a label is legal unescaped.
            let raw = inlineChildren(element, markdown: markdown, depth: depth)
            let content = trimBlock(raw)
            guard markdown, !content.isEmpty else { return raw }
            // The delimiter must outlive the longest backtick run inside;
            // content that begins or ends with a backtick gets a space of
            // padding (CommonMark 6.1 — ` ``x`` ` needs the spaces to parse).
            let fence = String(repeating: "`", count: longestBacktickRun(content) + 1)
            let padded = content.hasPrefix("`") || content.hasSuffix("`")
            return withEdgeSpaces(
                raw, around:
                    fence + (padded ? " " : "") + content + (padded ? " " : "") + fence)
        case "a":
            let raw = inlineChildren(
                element, markdown: markdown, depth: depth, inLinkLabel: true)
            let content = trimBlock(raw)
            guard markdown else { return raw }
            let href = ((try? element.attr("href")) ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, !href.isEmpty,
                !href.lowercased().hasPrefix("javascript:"), !href.hasPrefix("#"),
                Self.isLinkable(href, schemes: Self.linkableSchemes)
            else { return raw }
            let absolute = (try? element.absUrl("href")) ?? href
            return withEdgeSpaces(raw, around: linkMarkdown(content, href: absolute))
        case "img":
            let alt = ((try? element.attr("alt")) ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard markdown else { return alt }
            let src = ((try? element.attr("src")) ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard Self.isLinkable(src, schemes: Self.imageSchemes),
                let absolute = try? element.absUrl("src"), !absolute.isEmpty
            else { return alt }
            return "![\(alt)](\(absolute))"
        case "strong", "b":
            let raw = inlineChildren(
                element, markdown: markdown, depth: depth, inLinkLabel: inLinkLabel)
            let content = trimBlock(raw)
            guard markdown, !content.isEmpty else { return raw }
            return withEdgeSpaces(raw, around: "**\(content)**")
        case "em", "i":
            let raw = inlineChildren(
                element, markdown: markdown, depth: depth, inLinkLabel: inLinkLabel)
            let content = trimBlock(raw)
            guard markdown, !content.isEmpty else { return raw }
            return withEdgeSpaces(raw, around: "*\(content)*")
        default:
            return inlineChildren(
                element, markdown: markdown, depth: depth, inLinkLabel: inLinkLabel)
        }
    }

    /// `x<b> y </b>z` needs its edge whitespace OUTSIDE the delimiters —
    /// `** y **` won't parse (CommonMark 6.2: `**` can't carry inner spaces)
    /// — so each side of `raw` that carried whitespace gives one literal space.
    private static func withEdgeSpaces(_ raw: String, around delimited: String) -> String {
        (raw.first?.isWhitespace == true ? " " : "")
            + delimited
            + (raw.last?.isWhitespace == true ? " " : "")
    }

    /// Collapse, never trim — a `<span> </span>` between words IS their space;
    /// trimming happens at the block level. A block-level child met in inline
    /// context still separates: `<td><p>alpha</p><p>beta</p></td>` is
    /// "alpha beta", not "alphabeta".
    private static func inlineChildren(
        _ element: Element, markdown: Bool, depth: Int, inLinkLabel: Bool = false
    ) -> String {
        collapseLines(element.getChildNodes().map { node in
            if let child = node as? Element, isBlock(child, depth: depth + 1) {
                return " " + inline(
                    child, markdown: markdown, depth: depth + 1,
                    inLinkLabel: inLinkLabel) + " "
            }
            return inline(
                node, markdown: markdown, depth: depth + 1,
                inLinkLabel: inLinkLabel)
        }.joined())
    }

    /// One text node's whitespace runs → one space — boundary spaces survive so
    /// siblings join correctly.
    private static func collapse(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"[ \t\xA0\n\r]+"#, with: " ", options: .regularExpression)
    }

    /// `collapse` per line — a `br`'s newline stays a newline, edges untrimmed.
    private static func collapseLines(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map {
                $0.replacingOccurrences(
                    of: #"[ \t\xA0]+"#, with: " ", options: .regularExpression)
            }
            .joined(separator: "\n")
    }

    /// Per-line collapse + trim (a `br`'s newline stays a newline) and edge trim —
    /// the "each block is trimmed" rule.
    private static func trimBlock(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map {
                $0.replacingOccurrences(
                    of: #"[ \t\xA0]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every line of a block is shielded from opening a block — a `br` line or a
    /// continuation can carry a marker just like a paragraph start. Markdown
    /// only: plain text carries no markers and so needs no shielding.
    private static func escapeLineStarts(_ text: String, markdown: Bool) -> String {
        guard markdown else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { escapeLineStart(String($0)) }
            .joined(separator: "\n")
    }

    /// One line, one backslash when its first characters would open a block —
    /// the whole of the escaping stance. A leading `[` is left alone unless the
    /// line is a link reference definition (`[x]:`), which renders invisibly.
    private static func escapeLineStart(_ line: String) -> String {
        guard let first = line.first else { return line }
        // `# heading`, `> quote` — one backslash ahead.
        if first == "#" || first == ">" { return "\\" + line }
        // `- `/`+ `/`* ` — a bullet.
        if (first == "-" || first == "+" || first == "*"),
            line.dropFirst().first == " "
        { return "\\" + line }
        // A ``` or ~~~ run — a fence opener would swallow everything to EOF.
        if (first == "`" || first == "~"),
            line.hasPrefix(String(repeating: first, count: 3))
        { return "\\" + line }
        // A line of only 3+ repeats of one marker — a rule or setext line.
        if line.count >= 3, "`~*_=-".contains(first),
            line.allSatisfy({ $0 == first })
        { return "\\" + line }
        // `<x`, `</`, `<!` — an HTML block opener.
        if first == "<", let second = line.dropFirst().first,
            second.isLetter || second == "/" || second == "!"
        { return "\\" + line }
        // `12. `/`12) ` — an ordered item; the marker char takes the backslash.
        if first.isNumber {
            var i = line.startIndex
            while i < line.endIndex, line[i].isNumber { i = line.index(after: i) }
            if i < line.endIndex, line[i] == "." || line[i] == ")" {
                let after = line.index(after: i)
                if after < line.endIndex, line[after] == " " {
                    return String(line[..<i]) + "\\" + String(line[i]) + line[after...]
                }
            }
            return line
        }
        // `[x]:` — a link reference definition is invisible content. A line that
        // merely starts with a link (`[text](url)`) has no `]:` and stays.
        if first == "[", let close = line.firstIndex(of: "]") {
            let after = line.index(after: close)
            if after < line.endIndex, line[after] == ":" { return "\\" + line }
        }
        return line
    }
}
