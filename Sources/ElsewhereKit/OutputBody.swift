public import Foundation // Data is public API

/// What `fetch` puts in the body's slot — the single place decode → render → page
/// happens, so `--head`, `--format raw` and the binary notice can't drift apart
/// between the stdout and `--json` paths (§5.6).
public enum OutputBody {
    /// The caller's next step for a result:
    /// - `.bytes`: write the data verbatim — `raw` is the wire body, never
    ///   decoded, rendered or paged (a 1251 page stays 1251 bytes).
    /// - `.text`: rendered, paged text for stdout.
    /// - `.undecodable`: `TextDecoder` declined — the caller prints the
    ///   binary/`--output` notice.
    /// - `.none`: a HEAD response — there is no body in any output mode.
    public enum Selection: Sendable, Equatable {
        case bytes(Data)
        case text(String)
        case undecodable
        case none
    }

    /// `head` wins every mode — a HEAD response renders nothing. `raw` hands back
    /// the response bytes unpaged. markdown/text decode, render and page.
    public static func select(
        _ result: FetchResult, format: OutputFormat,
        startIndex: Int, maxLength: Int, head: Bool
    ) -> Selection {
        guard !head else { return .none }
        guard format != .raw else { return .bytes(result.body) }
        guard let decoded = TextDecoder.decode(
            result.body, contentType: result.contentType)
        else { return .undecodable }
        return .text(Pager.slice(
            Renderer.render(
                decoded.text, contentType: result.contentType,
                finalURL: result.finalURL, format: format),
            startIndex: startIndex, maxLength: maxLength))
    }

    /// The `--json` `body` for a selection — JSON cannot carry bytes, so a raw
    /// result contributes its decoded text; `--head` and a binary body contribute
    /// `null`.
    public static func json(_ selection: Selection, of result: FetchResult) -> String? {
        switch selection {
        case .text(let text): return text
        case .bytes(let data):
            return TextDecoder.decode(data, contentType: result.contentType)?.text
        case .undecodable, .none:
            return nil
        }
    }
}
