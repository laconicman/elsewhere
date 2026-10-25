import ElsewhereKit
import Foundation
import Testing

/// fd 1 is the engine's sink after ``OwnStdout/claim()``; a direct write to it would
/// vanish — or land in the MCP stream. Every writer goes through `OwnStdout.handle`.
@Suite("OwnStdout — nothing writes to descriptor 1 directly")
struct OwnStdoutTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources")

    @Test func beforeAClaimTheHandleIsPlainStdout() {
        #expect(OwnStdout.handle === FileHandle.standardOutput)
    }

    @Test func noSourceWritesToDescriptorOneDirectly() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "OwnStdout.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("///") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if line.contains("FileHandle.standardOutput") || line.contains("FileDescriptor.standardOutput") || line.contains("print(") {
                    offenders.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
