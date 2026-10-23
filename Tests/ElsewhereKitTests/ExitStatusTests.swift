import Foundation
import Testing
@testable import ElsewhereKit

/// The exit-status contract — devin-kick's shape: `rows` is the one source, and this
/// suite pins the README table, `--help`'s discussion and every `ElsewhereError` case to
/// it. The three change together or not at all.
@Suite("ExitStatus — rows == errors == README table")
struct ExitStatusTests {
    private var readme: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // ElsewhereKitTests/
                .deletingLastPathComponent()  // Tests/
                .deletingLastPathComponent()  // repo root
                .appending(path: "README.md")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test func everyErrorCaseMapsToADocumentedRow() {
        for error in [ElsewhereError.engine("x"), .tunnel("x"), .fetch("x"), .refused("x"),
                      .config("x"), .exit("x"), .usage("x")] {
            #expect(ExitStatus.meaning(of: error.exitStatus) != nil, "\(error) has no row")
        }
    }

    @Test(arguments: ExitStatus.rows.map(\.code))
    func readmeListsTheRow(_ code: Int32) throws {
        #expect(try readme.contains("| \(code) | "))
        for row in ExitStatus.rows where row.code == code {
            #expect(try readme.contains("| \(row.code) | \(row.meaning) |"))
        }
    }

    @Test func readmeRowsAreOnlyTheDocumentedOnes() throws {
        let lines = try readme.split(separator: "\n").filter { $0.hasPrefix("| ") }
            .filter { !$0.contains("---") && !$0.contains("Code") }
        // `split` omits empty subsequences, so cell 0 is the first pipe's content.
        let codes = lines.compactMap {
            Int32($0.split(separator: "|")[0].trimmingCharacters(in: .whitespaces))
        }
        #expect(codes.sorted() == ExitStatus.rows.map(\.code).sorted())
    }

    @Test func helpCoversEveryRow() {
        for row in ExitStatus.rows {
            let code = String(row.code)
            let line = "  " + code + String(repeating: " ", count: 4 - code.count) + row.meaning
            #expect(ExitStatus.help.contains(line))
        }
    }
}
