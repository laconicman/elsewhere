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
