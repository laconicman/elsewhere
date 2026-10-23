public import Foundation // Data is public API

/// Bytes → text for `fetch`: only text-like content types decode at all — the caller
/// treats `nil` as binary and offers `--output`. Encoding, in order: the `charset=`
/// parameter, a BOM, a `<meta charset>`/`http-equiv` sniff inside the first 2 KB
/// (read as Latin-1 — the marker itself is ASCII in any of these encodings), UTF-8,
/// then windows-1251 when UTF-8 fails to decode (the archive.org lesson — Cyrillic
/// pages older than the web's UTF-8 habit).
public enum TextDecoder {
    /// - Returns: the decoded text and the encoding name used; `nil` for a non-text
    ///   content type. The returned name is what the caller reports (`utf-8`,
    ///   `windows-1251`, or the declared charset).
    public static func decode(_ body: Data, contentType: String?) -> (text: String, encoding: String)? {
        guard isTextual(contentType) else { return nil }
        if let charset = charsetParameter(of: contentType),
            let encoding = iana(charset),
            let text = String(data: body, encoding: encoding)
        { return (text, charset) }
        if body.starts(with: [0xEF, 0xBB, 0xBF]) {
            if let text = String(data: body.dropFirst(3), encoding: .utf8) {
                return (text, "utf-8")
            }
        }
        if body.starts(with: [0xFF, 0xFE]) || body.starts(with: [0xFE, 0xFF]) {
            // .unicode sniffs the BOM and decodes the right endianness.
            if let text = String(data: body, encoding: .utf16) {
                return (text, "utf-16")
            }
        }
        if let charset = sniffedCharset(in: body),
            let encoding = iana(charset),
            let text = String(data: body, encoding: encoding)
        { return (text, charset) }
        if let text = String(data: body, encoding: .utf8) { return (text, "utf-8") }
        if let text = String(data: body, encoding: .windowsCP1251) {
            return (text, "windows-1251")
        }
        return nil
    }

    /// `text/*`, JSON/XML/XHTML/JavaScript, and `+json`/`+xml` suffixes. No content
    /// type at all means "not known to be text" — the caller offers `--output`.
    static func isTextual(_ contentType: String?) -> Bool {
        guard let mediaType = contentType?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        else { return false }
        if mediaType.hasPrefix("text/") { return true }
        if mediaType.hasSuffix("+json") || mediaType.hasSuffix("+xml") { return true }
        return [
            "application/json", "application/xml",
            "application/xhtml+xml", "application/javascript",
        ].contains(mediaType)
    }

    /// The `charset=…` parameter of a Content-Type value, if present.
    static func charsetParameter(of contentType: String?) -> String? {
        contentType?.split(separator: ";").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.lowercased().hasPrefix("charset=") }
            .map { String($0.dropFirst("charset=".count)) }
    }

    /// `<meta charset=…>` or `<meta http-equiv … charset=…>` inside the first 2 KB.
    /// The head is decoded as Latin-1 — every byte maps, and `charset` is ASCII.
    static func sniffedCharset(in body: Data) -> String? {
        guard let head = String(data: body.prefix(2048), encoding: .isoLatin1),
            let match = head.firstMatch(of: /charset\s*=\s*["']?([A-Za-z0-9_-]+)/)
        else { return nil }
        return String(match.1)
    }

    /// IANA name → `String.Encoding` via CFString's tables (`koi8-r`, `utf-8`,
    /// `windows-1251`, … all understood); nil when the name is unknown.
    static func iana(_ name: String) -> String.Encoding? {
        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }
}
