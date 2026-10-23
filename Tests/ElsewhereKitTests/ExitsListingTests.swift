import Foundation
import Testing
@testable import ElsewhereKit

/// `exits list`: one line per exit, name-sorted, `[default]` on the chosen one; an empty
/// config prints the nudge instead of nothing.
@Suite("ExitsListing — one redacted line per exit")
struct ExitsListingTests {
    @Test func emptyConfigPrintsTheNudge() {
        #expect(ExitsListing.lines(for: ElsewhereConfig()) == [
            "no exits; add one with `elsewhere exits add NAME --link …`"])
    }

    @Test func sortedLinesMarkTheDefault() {
        let config = ElsewhereConfig(
            default: "moldova",
            exits: [
                "zzz": .proxy(URL(string: "http://127.0.0.1:10808")!),
                "moldova": .link(Synthetic.link),
            ])
        let lines = ExitsListing.lines(for: config)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("moldova  link vless://"))
        #expect(lines[0].hasSuffix("[default]"))
        #expect(lines[1] == "zzz  proxy http://127.0.0.1:10808")
        for secret in Synthetic.secrets {
            #expect(!lines.joined().contains(secret))
        }
    }
}
