import Foundation
import Testing
@testable import ElsewhereKit

/// The generated Xray config, pinned byte-for-byte by golden fixtures (produced once by
/// the builder itself — `ELSEWHERE_WRITE_GOLDENS=1 swift test --filter writeGoldens` —
/// reviewed against plan §5.3, then frozen; never typed as text).
@Suite("XrayConfigBuilder — goldens and normalisation", .temporaryDirectories)
struct XrayConfigBuilderTests {
    /// The flat outbound libXray emits for ``Synthetic/link`` (spike S2) — with
    /// `sendThrough` and a stray `tag` to prove normalisation overwrites both.
    static func spikeOutbound() throws -> JSONValue {
        try JSONDecoder().decode(
            JSONValue.self,
            from: Data("""
                {"protocol":"vless","tag":"Spike Exit","sendThrough":"1.2.3.4",
                "settings":{"address":"proxy.example.com","port":8443,
                "id":"\(Synthetic.uuid)","encryption":"none"},
                "streamSettings":{"network":"xhttp","security":"reality",
                "realitySettings":{"fingerprint":"chrome","serverName":"www.example.com",
                "password":"\(Synthetic.pbk)","shortId":"\(Synthetic.sid)"},
                "xhttpSettings":{"path":"/xhttp","mode":"stream-one"}}}
                """.utf8))
    }

    /// A second invented exit for the two-exits golden.
    static func kzOutbound() throws -> JSONValue {
        try JSONDecoder().decode(
            JSONValue.self,
            from: Data("""
                {"protocol":"shadowsocks","settings":{"address":"kz.example.com",
                "port":8388,"method":"aes-256-gcm","password":"invented-too"},
                "streamSettings":{"network":"tcp"}}
                """.utf8))
    }

    static func parsed(_ configJSON: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(configJSON.utf8)) as? [String: Any])
    }

    static func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        // The files carry a POSIX trailing newline; the builder's output does not.
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    // MARK: - Goldens

    @Test func oneExitBoundMatchesGolden() throws {
        let (configJSON, _) = try XrayConfigBuilder.build(
            exits: [("moldova", Self.spikeOutbound())],
            ports: ["moldova": 49152],
            directPort: 49154,
            bindInterface: "en0")
        #expect(configJSON == (try Self.fixture("one-exit-bound")))
        // `.sortedKeys` renders the Double port as the integer Xray wants (uint16).
        #expect(configJSON.contains("\"port\":49152"))
    }

    @Test func twoExitsBoundMatchGolden() throws {
        let (configJSON, _) = try XrayConfigBuilder.build(
            exits: [("moldova", Self.spikeOutbound()), ("kz", Self.kzOutbound())],
            ports: ["moldova": 49152, "kz": 49153],
            directPort: 49154,
            bindInterface: "en0")
        #expect(configJSON == (try Self.fixture("two-exits-bound")))
    }

    @Test func oneExitUnboundMatchesGolden() throws {
        let (configJSON, _) = try XrayConfigBuilder.build(
            exits: [("moldova", Self.spikeOutbound())],
            ports: ["moldova": 49152],
            directPort: 49154,
            bindInterface: nil)
        #expect(configJSON == (try Self.fixture("one-exit-unbound")))
    }

    @Test func oneExitWithoutDirectMatchesGolden() throws {
        // A9: `fetch --exit moldova` binds its lane and nothing else — `directPort:
        // nil` emits no in:direct/out:direct/rule/lane.
        let (configJSON, lanes) = try XrayConfigBuilder.build(
            exits: [("moldova", Self.spikeOutbound())],
            ports: ["moldova": 49152],
            directPort: nil,
            bindInterface: "en0")
        #expect(configJSON == (try Self.fixture("one-exit-no-direct")))
        #expect(lanes.count == 1)
        #expect(!configJSON.contains("direct"))
    }

    @Test func fileLogMatchesGolden() throws {
        let (configJSON, _) = try XrayConfigBuilder.build(
            exits: [("moldova", Self.spikeOutbound())],
            ports: ["moldova": 49152],
            directPort: 49154,
            bindInterface: nil,
            log: .file("/tmp/xray.log"))
        #expect(configJSON == (try Self.fixture("one-exit-file-log")))
        // JSONSerialization escapes "/" as "\/", so match the log block's keys instead.
        #expect(configJSON.contains("\"log\":{\"access\":\"none\",\"error\":"))
        #expect(configJSON.contains("\"loglevel\":\"warning\""))
    }

    /// The goldens' provenance — run `ELSEWHERE_WRITE_GOLDENS=1 swift test --filter
    /// writeGoldens` to regenerate; skipped otherwise.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ELSEWHERE_WRITE_GOLDENS"] == "1"))
    func writeGoldens() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appending(path: "Fixtures", directoryHint: .isDirectory)
        let cases: [(String, String)] = [
            ("one-exit-bound", try XrayConfigBuilder.build(
                exits: [("moldova", Self.spikeOutbound())], ports: ["moldova": 49152],
                directPort: 49154, bindInterface: "en0").configJSON),
            ("two-exits-bound", try XrayConfigBuilder.build(
                exits: [("moldova", Self.spikeOutbound()), ("kz", Self.kzOutbound())],
                ports: ["moldova": 49152, "kz": 49153],
                directPort: 49154, bindInterface: "en0").configJSON),
            ("one-exit-unbound", try XrayConfigBuilder.build(
                exits: [("moldova", Self.spikeOutbound())], ports: ["moldova": 49152],
                directPort: 49154, bindInterface: nil).configJSON),
            ("one-exit-no-direct", try XrayConfigBuilder.build(
                exits: [("moldova", Self.spikeOutbound())], ports: ["moldova": 49152],
                directPort: nil, bindInterface: "en0").configJSON),
            ("one-exit-file-log", try XrayConfigBuilder.build(
                exits: [("moldova", Self.spikeOutbound())], ports: ["moldova": 49152],
                directPort: 49154, bindInterface: nil, log: .file("/tmp/xray.log")).configJSON),
        ]
        for (name, json) in cases {
            try Data((json + "\n").utf8).write(to: dir.appending(path: "\(name).json"))
        }
    }

    // MARK: - Normalisation

    @Test func normalisationOverwritesTagAndDropsSendThrough() throws {
        let (configJSON, _) = try XrayConfigBuilder.build(
            exits: [("moldova", Self.spikeOutbound())],
            ports: ["moldova": 49152], directPort: 49154, bindInterface: "en0")
        let root = try JSONSerialization.jsonObject(
            with: Data(configJSON.utf8)) as? [String: Any]
        let outbound = try #require((root?["outbounds"] as? [[String: Any]])?.first)
        #expect(outbound["tag"] as? String == "out:moldova")
        #expect(outbound["sendThrough"] == nil)
    }

    @Test func missingProtocolIsRejected() {
        #expect(throws: ElsewhereError.self) {
            _ = try XrayConfigBuilder.build(
                exits: [("moldova", .object(["settings": .object([:])]))],
                ports: ["moldova": 49152], directPort: 49154, bindInterface: nil)
        }
    }

    @Test func missingPortIsRejected() {
        #expect(throws: ElsewhereError.self) {
            _ = try XrayConfigBuilder.build(
                exits: [("moldova", .object(["protocol": .string("vless")]))],
                ports: [:], directPort: 49154, bindInterface: nil)
        }
    }

    @Test func interfaceMergeKeepsSiblings() throws {
        let outbound = try JSONDecoder().decode(
            JSONValue.self,
            from: Data("""
                {"protocol":"vless","settings":{},
                "streamSettings":{"network":"xhttp","sockopt":{"tcpFastOpen":true}}}
                """.utf8))
        let (configJSON, _) = try XrayConfigBuilder.build(
            exits: [("moldova", outbound)],
            ports: ["moldova": 49152], directPort: 49154, bindInterface: "en0")
        let root = try JSONSerialization.jsonObject(
            with: Data(configJSON.utf8)) as? [String: Any]
        let first = try #require((root?["outbounds"] as? [[String: Any]])?.first)
        let stream = try #require(first["streamSettings"] as? [String: Any])
        let sockopt = try #require(stream["sockopt"] as? [String: Any])
        #expect(stream["network"] as? String == "xhttp")
        #expect(sockopt["tcpFastOpen"] as? Bool == true)
        #expect(sockopt["interface"] as? String == "en0")
    }

    // MARK: - The direct lane's DNS (TD-4)

    /// The `dns` block, the `inboundTag:["dns"] → out:direct` steering rule and
    /// `ForceIPv4v6` on `out:direct`'s sockopt — the whole bound-lane contract.
    @Test func aBoundDirectGetsDNSForceStrategyAndTheSteeringRule() throws {
        let (configJSON, _) = try XrayConfigBuilder.build(
            exits: [("moldova", Self.spikeOutbound())],
            ports: ["moldova": 49152], directPort: 49154, bindInterface: "en0",
            directDNS: ["https://9.9.9.9/dns-query", "https://[2620:fe::fe]/dns-query"])
        let root = try Self.parsed(configJSON)
        let dns = try #require(root["dns"] as? [String: Any])
        #expect(
            dns["servers"] as? [String]
                == ["https://9.9.9.9/dns-query", "https://[2620:fe::fe]/dns-query"])
        #expect(dns["tag"] as? String == "dns")
        let rules = try #require(
            (root["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        #expect(rules.contains {
            $0["inboundTag"] as? [String] == ["dns"]
                && $0["outboundTag"] as? String == "out:direct"
        })
        let outbounds = try #require(root["outbounds"] as? [[String: Any]])
        let direct = try #require(
            outbounds.first { $0["tag"] as? String == "out:direct" })
        let sockopt = try #require(
            (direct["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any])
        #expect(sockopt["domainStrategy"] as? String == "ForceIPv4v6")
        #expect(sockopt["interface"] as? String == "en0")
    }

    /// `--via-system`: direct is simply the system path, name lookup included —
    /// no `dns` block, no `dns` rule, no sockopt at all on the freedom outbound.
    @Test func anUnboundDirectIsTheSystemPathLookupIncluded() throws {
        let (configJSON, _) = try XrayConfigBuilder.build(
            exits: [("moldova", Self.spikeOutbound())],
            ports: ["moldova": 49152], directPort: 49154, bindInterface: nil,
            directDNS: ["https://9.9.9.9/dns-query"])
        let root = try Self.parsed(configJSON)
        #expect(root["dns"] == nil)
        let rules = try #require(
            (root["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        #expect(
            rules.allSatisfy {
                ($0["inboundTag"] as? [String])?.contains("dns") != true
            })
        let outbounds = try #require(root["outbounds"] as? [[String: Any]])
        let direct = try #require(
            outbounds.first { $0["tag"] as? String == "out:direct" })
        #expect(direct["protocol"] as? String == "freedom")
        #expect(direct["streamSettings"] == nil)
    }

    /// An unbound lane never reads `directDNS` — not even to reject it.
    @Test func anUnboundDirectSkipsDirectDNSValidation() throws {
        _ = try XrayConfigBuilder.build(
            exits: [("moldova", Self.spikeOutbound())],
            ports: ["moldova": 49152], directPort: 49154, bindInterface: nil,
            directDNS: ["not a url"])
    }

    /// Exits stay `AsIs` — the `dns` block exists for `direct` only.
    @Test func exitOutboundsCarryNoDomainStrategy() throws {
        let (configJSON, _) = try XrayConfigBuilder.build(
            exits: [("moldova", Self.spikeOutbound())],
            ports: ["moldova": 49152], directPort: 49154, bindInterface: "en0",
            directDNS: ["https://9.9.9.9/dns-query"])
        let root = try Self.parsed(configJSON)
        let outbounds = try #require(root["outbounds"] as? [[String: Any]])
        let exit = try #require(
            outbounds.first { $0["tag"] as? String == "out:moldova" })
        let sockopt = try #require(
            (exit["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any])
        #expect(sockopt["interface"] as? String == "en0")
        #expect(sockopt["domainStrategy"] == nil)
    }

    /// No direct lane → no `dns` key and no dns rule, servers given or not.
    @Test func noDirectLaneMeansNoDNSBlock() throws {
        let (configJSON, _) = try XrayConfigBuilder.build(
            exits: [("moldova", Self.spikeOutbound())],
            ports: ["moldova": 49152], directPort: nil, bindInterface: "en0",
            directDNS: ["https://9.9.9.9/dns-query"])
        let root = try Self.parsed(configJSON)
        #expect(root["dns"] == nil)
        let rules = try #require(
            (root["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        #expect(
            rules.allSatisfy {
                ($0["inboundTag"] as? [String])?.contains("dns") != true
            })
    }

    /// A hostname would bootstrap through the system resolver; a non-https
    /// scheme would bypass routing (DOHL); no path is no endpoint.
    @Test(arguments: [
        "http://1.1.1.1/dns-query",
        "https+local://1.1.1.1/dns-query",
        "https://dns.google/dns-query",
        "https://one.one.one.one/dns-query",
        "https://1.1.1.1",
        "https://[cloudflare-dns.com]/dns-query",
        "not a url",
        "",
    ])
    func anInvalidDirectDNSEntryIsAConfigError(entry: String) {
        do {
            _ = try XrayConfigBuilder.build(
                exits: [("moldova", Self.spikeOutbound())],
                ports: ["moldova": 49152], directPort: 49154, bindInterface: "en0",
                directDNS: [entry])
            Issue.record("expected .config for '\(entry)'")
        } catch ElsewhereError.config(let message) {
            #expect(message.contains("https://<ip>/path"))
        } catch { Issue.record("expected .config, got \(error)") }
    }

    @Test func anEmptyDirectDNSListIsAConfigError() {
        do {
            _ = try XrayConfigBuilder.build(
                exits: [("moldova", Self.spikeOutbound())],
                ports: ["moldova": 49152], directPort: 49154, bindInterface: "en0",
                directDNS: [])
            Issue.record("expected .config")
        } catch ElsewhereError.config {
        } catch { Issue.record("expected .config, got \(error)") }
    }

    @Test func lanesCarryPortsAndTags() throws {
        let (_, lanes) = try XrayConfigBuilder.build(
            exits: [("moldova", Self.spikeOutbound()), ("kz", Self.kzOutbound())],
            ports: ["moldova": 49152, "kz": 49153],
            directPort: 49154, bindInterface: "en0")
        let expected: [XrayConfigBuilder.Lane] = [
            .init(exitName: "moldova", inboundPort: 49152, inboundTag: "in:moldova", outboundTag: "out:moldova"),
            .init(exitName: "kz", inboundPort: 49153, inboundTag: "in:kz", outboundTag: "out:kz"),
            .init(exitName: "direct", inboundPort: 49154, inboundTag: "in:direct", outboundTag: "out:direct"),
        ]
        #expect(lanes == expected)
    }
}
