import Foundation
import Testing
@testable import ElsewhereKit

/// The link is the secret: every printable form — a redacted link, a JSON tree, a
/// one-line summary, an engine error — keeps the structure and drops the credentials.
@Suite("Redactor — structure stays, secrets never do")
struct RedactorTests {
    /// The flat outbound libXray v26.10.21 emits for ``Synthetic.link`` (spike S2).
    static let flatOutbound = """
        {"protocol":"vless","tag":"Spike Exit","settings":{"address":"proxy.example.com",
        "port":8443,"id":"\(Synthetic.uuid)","encryption":"none"},
        "streamSettings":{"network":"xhttp","security":"reality",
        "realitySettings":{"fingerprint":"chrome","serverName":"www.example.com",
        "password":"\(Synthetic.pbk)","shortId":"\(Synthetic.sid)"},
        "xhttpSettings":{"path":"/xhttp","mode":"stream-one"}}}
        """

    static func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func linkKeepsShapeAndDropsSecrets() {
        let redacted = Redactor.redact(link: Synthetic.link)
        #expect(redacted.contains("vless://"))
        #expect(redacted.contains("proxy.example.com:8443"))
        #expect(redacted.contains("type=xhttp"))
        #expect(redacted.contains("security=reality"))
        #expect(redacted.contains("mode=stream-one"))
        #expect(redacted.contains("#Spike Exit"))
        for secret in Synthetic.secrets + ["www.example.com"] {
            #expect(!redacted.contains(secret), "leaked \(secret) in \(redacted)")
        }
    }

    @Test func linkSecretsAreEnumerated() {
        #expect(Set(Redactor.secrets(inLink: Synthetic.link)) == Set(Synthetic.secrets))
    }

    @Test func flatOutboundSecretsAreReplaced() throws {
        let redacted = Redactor.redact(try Self.json(Self.flatOutbound))
        guard case .object(let object) = redacted else {
            Issue.record("not an object")
            return
        }
        guard case .object(let settings) = object["settings"],
            case .object(let stream) = object["streamSettings"],
            case .object(let reality) = stream["realitySettings"]
        else {
            Issue.record("structure lost")
            return
        }
        #expect(settings["id"] == .string("…"))
        #expect(settings["address"] == .string("proxy.example.com"))
        #expect(settings["port"] == .number(8443))
        #expect(reality["password"] == .string("…"))
        #expect(reality["shortId"] == .string("…"))
        #expect(reality["serverName"] == .string("www.example.com"))
        #expect(stream["network"] == .string("xhttp"))
    }

    @Test func classicVnextSecretsAreReplaced() throws {
        let classic = try Self.json("""
            {"protocol":"vless","settings":{"vnext":[{"address":"a.example.com","port":443,
            "users":[{"id":"\(Synthetic.uuid)","encryption":"none"}]}]}}
            """)
        guard case .object(let object) = Redactor.redact(classic),
            case .object(let settings) = object["settings"],
            case .array(let vnext) = settings["vnext"],
            case .object(let first) = vnext.first,
            case .array(let users) = first["users"],
            case .object(let user) = users.first
        else {
            Issue.record("structure lost")
            return
        }
        #expect(user["id"] == .string("…"))
    }

    @Test func proxyUserinfoIsStripped() throws {
        let url = try #require(URL(string: "http://user:s3cret@127.0.0.1:10808"))
        let redacted = Redactor.redact(proxy: url)
        #expect(redacted == "http://…@127.0.0.1:10808")
        #expect(!redacted.contains("s3cret"))
    }

    @Test func proxyQueryAndFragmentAreDropped() throws {
        let url = try #require(
            URL(string: "http://u:pw@127.0.0.1:10808?password=zzz#frag"))
        let redacted = Redactor.redact(proxy: url)
        #expect(redacted == "http://…@127.0.0.1:10808")
        #expect(!redacted.contains("pw") && !redacted.contains("zzz"))
    }

    @Test func fragmentCannotRepeatASecret() {
        let link = Synthetic.link.replacingOccurrences(
            of: "#Spike%20Exit", with: "#\(Synthetic.uuid)")
        let redacted = Redactor.redact(link: link)
        #expect(redacted.contains("#…"))
        #expect(!redacted.contains(Synthetic.uuid))
    }

    @Test func scrubPatternsCatchesWhatSecretsCannotEnumerate() {
        let text = "engine: bad input \(Synthetic.link) / key \(Synthetic.pbk)"
        let scrubbed = Redactor.scrubPatterns(text)
        for secret in Synthetic.secrets + [Synthetic.link] {
            #expect(!scrubbed.contains(secret), "leaked \(secret) in \(scrubbed)")
        }
        #expect(scrubbed.contains("…"))
    }

    @Test func scrubPatternsLeavesOrdinaryText() {
        let text =
            "cannot read /tmp/elsewhere-smoke/config.json — first run, id 74682ba3"
        #expect(Redactor.scrubPatterns(text) == text)
    }

    @Test func summariesPerKind() throws {
        #expect(
            Redactor.summary(of: .link(Synthetic.link))
                == "link vless://…@proxy.example.com:8443"
                + "?type=xhttp&security=reality&pbk=…&sid=…&mode=stream-one#Spike Exit")
        #expect(
            Redactor.summary(of: .xray(try Self.json(Self.flatOutbound)))
                == "xray vless → proxy.example.com:8443")
        #expect(
            Redactor.summary(of: .proxy(URL(string: "http://127.0.0.1:10808")!))
                == "proxy http://127.0.0.1:10808")
    }

    @Test func outOfRangePortsRenderSafely() throws {
        // JSONValue numbers are Double; Int() would trap on these — a hand-edited exit
        // must crash nothing.
        let huge = try Self.json("""
            {"protocol":"vless","settings":{"address":"example.org","port":100000000000000000000}}
            """)
        #expect(
            Redactor.summary(of: .xray(huge)) == "xray vless → example.org:<invalid port>")
        let fractional = try Self.json("""
            {"protocol":"vless","settings":{"address":"example.org","port":8443.5}}
            """)
        #expect(
            Redactor.summary(of: .xray(fractional))
                == "xray vless → example.org:<invalid port>")
    }

    @Test func scrubReplacesEverySecret() {
        let text = "bad link \(Synthetic.link) — uuid \(Synthetic.uuid)"
        let scrubbed = Redactor.scrub(text, secrets: Redactor.secrets(inLink: Synthetic.link) + [Synthetic.link])
        for secret in Synthetic.secrets + [Synthetic.link] {
            #expect(!scrubbed.contains(secret))
        }
    }

    @Test func outboundSecretsAreCollected() throws {
        let outbound = try Self.json(Self.flatOutbound)
        let found = Set(Redactor.secrets(in: outbound))
        #expect(found.contains(Synthetic.uuid))
        #expect(found.contains(Synthetic.pbk))
        #expect(found.contains(Synthetic.sid))
        #expect(!found.contains("proxy.example.com"))
    }
}
