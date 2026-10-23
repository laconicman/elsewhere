import Foundation
import Testing
@testable import ElsewhereKit

/// `--max-length`/`--start-index` paging (§5.6) — slices are in `Character`s, the
/// marker carries `next_start_index`/`total` so an agent can continue reading.
@Suite("Pager — character paging")
struct PagerTests {
    @Test func unlimitedReturnsEverything() {
        #expect(Pager.slice("hello world", startIndex: 0, maxLength: 0) == "hello world")
        #expect(Pager.slice("hello world", startIndex: 6, maxLength: -1) == "world")
    }

    @Test func exactFitCarriesNoMarker() {
        #expect(Pager.slice("hello", startIndex: 0, maxLength: 5) == "hello")
        #expect(Pager.slice("hello", startIndex: 3, maxLength: 2) == "lo")
    }

    /// A marker ends the output with a newline — the same convention the
    /// rendered text follows; an unpaged slice keeps its own trailing newline.
    @Test func theMarkerIsNewlineTerminated() {
        #expect(Pager.slice("hello", startIndex: 0, maxLength: 2).hasSuffix(">\n"))
        #expect(Pager.slice("text\n", startIndex: 0, maxLength: 0) == "text\n")
    }

    @Test func aCutAppendsTheMarkerWithSaneCounts() {
        #expect(Pager.slice("hello world", startIndex: 0, maxLength: 5)
            == "hello\n<elsewhere:truncated next_start_index=5 total=11>\n")
        #expect(Pager.slice("hello world", startIndex: 5, maxLength: 3)
            == " wo\n<elsewhere:truncated next_start_index=8 total=11>\n")
    }

    @Test func startBeyondTotalIsTheMarkerAlone() {
        #expect(Pager.slice("hi", startIndex: 9, maxLength: 5)
            == "<elsewhere:truncated next_start_index=2 total=2>\n")
    }

    @Test func negativeStartClampsToZero() {
        #expect(Pager.slice("hello", startIndex: -3, maxLength: 2)
            == "he\n<elsewhere:truncated next_start_index=2 total=5>\n")
    }

    /// A grapheme cluster is one `Character`: the cut never splits an emoji or a
    /// combining sequence.
    @Test func cutsNeverSplitGraphemes() {
        let text = "a\u{1F1F7}\u{1F1FA}e\u{0301}z" // a 🇷🇺 é z — 4 characters
        #expect(text.count == 4)
        let cut = Pager.slice(text, startIndex: 0, maxLength: 2)
        #expect(cut == "a\u{1F1F7}\u{1F1FA}\n<elsewhere:truncated next_start_index=2 total=4>\n")
        #expect(Pager.slice(text, startIndex: 2, maxLength: 0) == "e\u{0301}z")
    }
}
