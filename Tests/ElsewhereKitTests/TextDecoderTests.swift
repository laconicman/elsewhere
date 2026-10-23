import Foundation
import Testing
@testable import ElsewhereKit

/// Bytes → text, in the order §5.5's decoder promises: charset parameter, BOM,
/// `<meta charset>` sniff in the first 2 KB, UTF-8, windows-1251 last. `nil` is the
/// binary answer.
@Suite("TextDecoder — charset, BOM, meta sniff, UTF-8, 1251")
struct TextDecoderTests {
    private let cp1251 = "Привет"
    private var cp1251Body: Data { cp1251.data(using: .windowsCP1251)! }

    @Test func charsetParameterWins() throws {
        // Body that would fail UTF-8 but the declared charset decodes it.
        let decoded = try #require(
            TextDecoder.decode(cp1251Body, contentType: "text/plain; charset=windows-1251"))
        #expect(decoded.text == cp1251)
        #expect(decoded.encoding == "windows-1251")
    }

    @Test func utf8BOMDecodesAsUTF8() throws {
        var body = Data([0xEF, 0xBB, 0xBF])
        body.append(Data("hello".utf8))
        let decoded = try #require(TextDecoder.decode(body, contentType: "text/html"))
        #expect(decoded.text == "hello")
        #expect(decoded.encoding == "utf-8")
    }

    @Test func utf16LEBOMDecodesAsUTF16() throws {
        var body = Data([0xFF, 0xFE])
        body.append("hello".data(using: .utf16LittleEndian)!)
        let decoded = try #require(TextDecoder.decode(body, contentType: "text/plain"))
        #expect(decoded.text == "hello")
        #expect(decoded.encoding == "utf-16")
    }

    @Test func metaCharsetIsSniffedInTheHead() throws {
        var head = "<html><head><meta charset=windows-1251></head><body>".data(using: .isoLatin1)!
        head.append(cp1251Body)
        let decoded = try #require(TextDecoder.decode(head, contentType: "text/html"))
        #expect(decoded.text.hasSuffix(cp1251))
        #expect(decoded.encoding == "windows-1251")
    }

    @Test func metaCharsetInsideHttpEquivIsSniffed() throws {
        let head = Data(("<html><head><meta http-equiv=\"Content-Type\" "
            + "content=\"text/html; charset=utf-8\"></head>").utf8)
        let decoded = try #require(TextDecoder.decode(head, contentType: "text/html"))
        #expect(decoded.encoding == "utf-8")
    }

    @Test func plainUTF8IsTheDefault() throws {
        let decoded = try #require(
            TextDecoder.decode(Data("héllo — wörld".utf8), contentType: "text/plain"))
        #expect(decoded.encoding == "utf-8")
    }

    @Test func invalidUTF8FallsBackTo1251() throws {
        let decoded = try #require(TextDecoder.decode(cp1251Body, contentType: "text/plain"))
        #expect(decoded.text == cp1251)
        #expect(decoded.encoding == "windows-1251")
    }

    @Test(arguments: [
        "application/octet-stream", "image/png", "application/zip",
        nil,
    ])
    func nonTextTypesAreNil(contentType: String?) throws {
        #expect(TextDecoder.decode(cp1251Body, contentType: contentType) == nil)
    }

    @Test(arguments: [
        "application/json", "application/xml", "application/xhtml+xml",
        "application/javascript", "application/hal+json", "application/atom+xml",
        "text/csv; charset=utf-8",
    ])
    func textLikeTypesDecode(contentType: String) throws {
        let decoded = try #require(
            TextDecoder.decode(Data("plain".utf8), contentType: contentType))
        #expect(decoded.text == "plain")
    }

    @Test func anUnknownCharsetFallsThroughToUTF8() throws {
        let decoded = try #require(
            TextDecoder.decode(Data("ok".utf8), contentType: "text/plain; charset=x-not-real"))
        #expect(decoded.encoding == "utf-8")
    }
}
