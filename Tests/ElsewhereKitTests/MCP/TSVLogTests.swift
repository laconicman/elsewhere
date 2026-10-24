import Foundation
import Testing
@testable import ElsewhereMCP

/// `TSVLog`'s row shape is the sink's invariant: one line, seven columns —
/// a value's control characters flatten to spaces, so no tool argument can
/// split or forge a row.
@Suite("TSVLog — one line per row, control characters flattened", .temporaryDirectories)
struct TSVLogTests {
    /// A tab in the exit column and tab/LF/CR in the URL land as spaces: the
    /// file holds one line of exactly seven columns, and its only control
    /// scalars are the six separators and the final newline.
    @Test func aValueCannotSplitOrForgeARow() throws {
        let url = temporaryDirectory().appending(path: "audit.tsv")
        let log = try TSVLog(path: url)
        log.log(event: "fetch", exit: "a\tb", url: "https://x/\ty\nz\r")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 1)
        let columns = lines[0].split(separator: "\t", omittingEmptySubsequences: false)
        #expect(columns.count == 7)
        #expect(columns[2] == "a b")
        #expect(columns[6].contains("y z"))
        let controls = text.unicodeScalars.filter {
            CharacterSet.controlCharacters.contains($0)
        }
        #expect(controls.count == 7) // six tabs and the final newline
        #expect(controls.prefix(6).allSatisfy { $0 == "\t" })
        #expect(controls.last == "\n")
    }
}
