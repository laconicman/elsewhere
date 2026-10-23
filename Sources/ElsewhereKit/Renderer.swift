public import Foundation // URL is public API
import SwiftSoup // the parser — never in the public surface (rule 1)

/// `fetch`'s `--format` (§5.6): `markdown` is the default, `text` the same pipeline
/// without the decorations, `raw` PR #2's byte-exact behaviour.
public enum OutputFormat: String, Sendable, CaseIterable {
    case markdown
    case text
    case raw
}

/// HTML → Markdown (§3.7, §5.6). One pass over SwiftSoup's DOM; the plumbing is
/// small enough to live in one file. What lands on stdout:
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

        if let chrome = try? document.select(
            "script, style, noscript, svg, nav, footer, header, aside, form, "
                + "iframe, template, [hidden], [aria-hidden=true]")
        { _ = try? chrome.remove() }

        let root = (try? document.select("main"))?.first()
            ?? (try? document.select("article"))?.first()
            ?? (try? document.select("[role=main]"))?.first()
            ?? document.body() ?? document

        let markdown = format == .markdown
        let blocks = blocks(of: root, markdown: markdown)
        var body = blocks.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if hadExternalScripts, body.count < jsShellThreshold {
            body = body.isEmpty ? jsShellNote : body + "\n\n" + jsShellNote
        }

        var out: [String] = []
        let title = ((try? document.title()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { out.append(markdown ? "# \(title)" : title) }
        if !body.isEmpty { out.append(body) }
        out.append("Source: \(finalURL.absoluteString)")
        return out.joined(separator: "\n\n") + "\n"
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
    /// The block children of `element`, each a string that is one block.
    private static func blocks(of element: Element, markdown: Bool) -> [String] {
        element.getChildNodes().flatMap { node -> [String] in
            if let text = node as? TextNode {
                let rendered = trimBlock(collapse(text.text()))
                return rendered.isEmpty
                    ? [] : [escapeBlockStart(rendered, markdown: markdown)]
            }
            guard let element = node as? Element else { return [] }
            return block(element, markdown: markdown)
        }
    }

    /// One element as blocks — the element-name switch is the whole contract.
    private static func block(_ element: Element, markdown: Bool) -> [String] {
        switch element.tagName().lowercased() {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(element.tagName().dropFirst()) ?? 1
            let text = inline(element, markdown: markdown)
            guard !text.isEmpty else { return [] }
            return [markdown ? String(repeating: "#", count: level) + " " + text : text]
        case "p", "figcaption", "address", "caption", "dt", "dd", "summary", "legend":
            let text = escapeBlockStart(inline(element, markdown: markdown),
                                        markdown: markdown)
            return text.isEmpty ? [] : [text]
        case "ul", "ol":
            return listItems(element, ordered: element.tagName() == "ol",
                             depth: 0, markdown: markdown)
        case "li":
            return ["- " + inline(element, markdown: markdown)]
        case "blockquote":
            let inner = blocks(of: element, markdown: markdown)
                .joined(separator: "\n\n")
            guard !inner.isEmpty else { return [] }
            return [inner.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")]
        case "pre":
            return [preBlock(element, markdown: markdown)]
        case "table":
            return table(element, markdown: markdown)
        case "hr":
            return ["---"]
        case "br":
            return []
        case "img":
            let text = inline(element, markdown: markdown)
            return text.isEmpty ? [] : [text]
        default:
            // A container (div, section, main, article, figure, details, dl, …) or an
            // unknown element: blocks inside become their own blocks, inline content
            // a paragraph.
            let children = blocks(of: element, markdown: markdown)
            if !children.isEmpty { return children }
            let text = escapeBlockStart(inline(element, markdown: markdown),
                                        markdown: markdown)
            return text.isEmpty ? [] : [text]
        }
    }

    /// `ul`/`ol` items, nested lists carried two spaces per level — the whole list
    /// is one block of lines. An `li`'s non-list children render inline; a nested
    /// `ul`/`ol` recurses at `depth + 1`.
    private static func listItems(
        _ list: Element, ordered: Bool, depth: Int, markdown: Bool
    ) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        var lines: [String] = []
        var number = 1
        for child in list.children() where child.tagName() == "li" {
            let bullet = ordered ? "\(number). " : "- "
            number += 1
            var ownText: [String] = []
            var nested: [String] = []
            for node in child.getChildNodes() {
                if let element = node as? Element,
                    ["ul", "ol"].contains(element.tagName().lowercased())
                {
                    nested += listItems(element, ordered: element.tagName() == "ol",
                                        depth: depth + 1, markdown: markdown)
                } else if let text = node as? TextNode {
                    ownText.append(collapse(text.text()))
                } else if let element = node as? Element {
                    ownText.append(inline(element, markdown: markdown))
                }
            }
            let text = trimBlock(ownText.joined())
            lines.append(indent + bullet + text)
            lines += nested
        }
        return lines.isEmpty ? [] : [lines.joined(separator: "\n")]
    }

    /// Fenced code: ` ```language `, content verbatim, ` ``` `. The language comes
    /// from `language-*`/`lang-*` on the `pre` or a `code` child; `text` format
    /// drops the fences, keeping the code as a plain block.
    private static func preBlock(_ pre: Element, markdown: Bool) -> String {
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
        let code = wholeText(pre).trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        return markdown ? "```\(language)\n\(code)\n```" : code
    }

    /// Every descendant text node verbatim — `pre` content keeps its whitespace.
    private static func wholeText(_ element: Element) -> String {
        element.getChildNodes().map { node in
            if let text = node as? TextNode { return text.getWholeText() }
            if let child = node as? Element { return wholeText(child) }
            return ""
        }.joined()
    }

    /// GFM table: the first `tr` carrying a `th` is the header — else the first row —
    /// then a `|---|` separator and the body rows. Cells flatten inline, `|` is
    /// escaped, newlines collapse to a space.
    private static func table(_ table: Element, markdown: Bool) -> [String] {
        guard let rows = try? table.select("tr"), rows.count > 0 else { return [] }
        func cells(_ row: Element) -> [String] {
            (try? row.select("th, td"))?.map { cell in
                inline(cell, markdown: markdown)
                    .replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\n", with: " ")
            } ?? []
        }
        let headerIndex = rows.firstIndex { row in
            ((try? row.select("th"))?.first()) != nil
        } ?? 0
        let header = cells(rows[headerIndex])
        guard !header.isEmpty else { return [] }
        var lines = ["| " + header.joined(separator: " | ") + " |"]
        lines.append("|" + String(repeating: "---|", count: header.count))
        for (index, row) in rows.enumerated() where index != headerIndex {
            let body = cells(row)
            if !body.isEmpty {
                lines.append("| " + body.joined(separator: " | ") + " |")
            }
        }
        return [lines.joined(separator: "\n")]
    }

    /// Everything inside one element as inline Markdown. Text nodes collapse —
    /// never trim — so a sibling keeps its boundary spaces; the edges trim at the
    /// block level.
    private static func inline(_ node: Node, markdown: Bool) -> String {
        if let text = node as? TextNode { return collapse(text.text()) }
        guard let element = node as? Element else { return "" }
        switch element.tagName().lowercased() {
        case "br": return "\n"
        case "code":
            let content = inlineChildren(element, markdown: markdown)
            if content.isEmpty { return "" }
            guard markdown else { return content }
            let fence = content.contains("`") ? "``" : "`"
            return fence + content + fence
        case "a":
            let content = inlineChildren(element, markdown: markdown)
            guard markdown else { return content }
            let href = ((try? element.attr("href")) ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, !href.isEmpty,
                !href.lowercased().hasPrefix("javascript:"), !href.hasPrefix("#")
            else { return content }
            let absolute = (try? element.absUrl("href")) ?? href
            return "[\(content)](\(absolute))"
        case "img":
            let alt = ((try? element.attr("alt")) ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard markdown else { return alt }
            let src = (try? element.absUrl("src")) ?? ""
            guard !src.isEmpty else { return alt }
            return "![\(alt)](\(src))"
        case "strong", "b":
            let content = inlineChildren(element, markdown: markdown)
            return markdown && !content.isEmpty ? "**\(content)**" : content
        case "em", "i":
            let content = inlineChildren(element, markdown: markdown)
            return markdown && !content.isEmpty ? "*\(content)*" : content
        default:
            return inlineChildren(element, markdown: markdown)
        }
    }

    private static func inlineChildren(_ element: Element, markdown: Bool) -> String {
        trimBlock(element.getChildNodes()
            .map { inline($0, markdown: markdown) }.joined())
    }

    /// One text node's whitespace runs → one space — boundary spaces survive so
    /// siblings join correctly.
    private static func collapse(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"[ \t\xA0\n\r]+"#, with: " ", options: .regularExpression)
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

    /// A paragraph whose first characters would open a block gets a backslash —
    /// the whole of the escaping stance (`#`/`>` at line start, `- `/`+ `/`* `, a
    /// `12. ` numbered-list start). Markdown only: plain text carries no markers
    /// and so needs no shielding.
    private static func escapeBlockStart(_ text: String, markdown: Bool) -> String {
        guard markdown, let first = text.first else { return text }
        if first == "#" || first == ">" { return "\\" + text }
        if (first == "-" || first == "+" || first == "*"),
            text.dropFirst().first == " "
        { return "\\" + text }
        if first.isNumber {
            var i = text.startIndex
            while i < text.endIndex, text[i].isNumber { i = text.index(after: i) }
            guard i < text.endIndex, text[i] == "." else { return text }
            let afterDot = text.index(after: i)
            if afterDot < text.endIndex, text[afterDot] == " " {
                return String(text[..<i]) + "\\." + text[afterDot...]
            }
        }
        return text
    }
}
