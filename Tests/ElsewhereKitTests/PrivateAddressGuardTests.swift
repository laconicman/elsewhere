import Foundation
import Testing
@testable import ElsewhereKit

/// §5.9 — private/local destinations are refused unless `--allow-private` says so;
/// non-http(s) is a usage error. Hostnames are not resolved (the exit resolves them).
@Suite("PrivateAddressGuard — private/local refused, everything else passes")
struct PrivateAddressGuardTests {
    private func refused(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        do {
            try PrivateAddressGuard.check(url, allowPrivate: false)
            Issue.record("expected .refused for \(raw)")
        } catch ElsewhereError.refused(let message) {
            #expect(message.contains("--allow-private"))
        }
    }

    private func allowed(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        try PrivateAddressGuard.check(url, allowPrivate: false)
    }

    @Test(arguments: [
        "http://localhost/", "http://foo.localhost/", "http://LOCALHOST./",
        "http://0.0.0.0/", "http://10.0.0.1/", "http://127.0.0.2/",
        "http://169.254.169.254/", "http://172.16.5.4/", "http://172.31.255.255/",
        "http://192.168.1.1/", "http://100.64.1.1/", "http://100.127.0.1/",
        "http://224.0.0.1/", "http://255.255.255.255/",
        "http://[::1]/", "http://[::]/", "http://[fc00::1]/", "http://[fd00::1]/",
        "http://[fe80::1]/", "http://[febf::1]/",
        "http://[::ffff:127.0.0.1]/", "http://[::ffff:10.1.2.3]/",
    ])
    func privateDestinationsAreRefused(raw: String) async throws {
        try refused(raw)
    }

    @Test(arguments: [
        "http://8.8.8.8/", "https://example.com/", "http://[2606:4700:4700::1111]/",
        "http://172.15.0.1/", "http://172.32.0.1/", "http://192.167.1.1/",
        "http://100.63.9.9/", "http://11.0.0.1/", "http://223.255.255.255/",
    ])
    func publicDestinationsPass(raw: String) async throws {
        try allowed(raw)
    }

    @Test func allowPrivateLiftsTheGuard() throws {
        for raw in ["http://127.0.0.1/", "http://localhost/", "http://[::1]/"] {
            let url = try #require(URL(string: raw))
            try PrivateAddressGuard.check(url, allowPrivate: true)
        }
    }

    @Test(arguments: ["ftp://example.com/f", "file:///etc/hosts", "gopher://h/"])
    func nonHTTPSchemesAreUsage(raw: String) throws {
        let url = try #require(URL(string: raw))
        do {
            try PrivateAddressGuard.check(url, allowPrivate: false)
            Issue.record("expected .usage for \(raw)")
        } catch ElsewhereError.usage(let message) {
            #expect(message.contains("http"))
        }
    }

    @Test func aURLWithoutAHostIsUsage() {
        do {
            try PrivateAddressGuard.check(URL(filePath: "/tmp/x"), allowPrivate: true)
            Issue.record("expected .usage")
        } catch ElsewhereError.usage {
        } catch {
            Issue.record("expected .usage, got \(error)")
        }
    }
}
