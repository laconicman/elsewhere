import ElsewhereKit
import Foundation
import Synchronization

/// `--log-tsv`'s sink: one append-only row per fetch/whoami and per lifecycle
/// edge — `date \t event \t exit \t status \t bytes \t ms \t url`, the date
/// ISO 8601 in UTC. Events: `fetch`, `whoami`, `up` (exit column the lane count),
/// `down` (exit column `idle`/`eof`/`signal`/`reopen`), `start-failed` (url
/// column the scrubbed message). Callers pass URLs through
/// `Redactor.redact(url:)` and free text through `scrubPatterns` — the log is an
/// audit trail, never a secrets file (0600, in a 0700 directory).
final class TSVLog: Sendable {
    /// `Mutex` is noncopyable — a class holds it (EngineGate's shape); every write
    /// is serialized through the lock.
    private let handle: Mutex<FileHandle>

    /// Opens `path` for appending, creating the file (0600) and its directory
    /// (0700) when absent — the same permissions the config file gets.
    init(path: URL) throws(ElsewhereError) {
        let fileManager = FileManager.default
        let directory = path.deletingLastPathComponent()
        do {
            // Only a directory we create gets tightened — an existing one
            // (`/tmp`, a Desktop folder) is the user's, never chmodded.
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            if !fileManager.fileExists(atPath: path.path) {
                guard fileManager.createFile(
                    atPath: path.path, contents: nil,
                    attributes: [.posixPermissions: 0o600])
                else { throw ElsewhereError.config("cannot create \(path.path)") }
            }
            let opened = try FileHandle(forWritingTo: path)
            _ = opened.seekToEndOfFile()
            handle = Mutex(opened)
        } catch let error as ElsewhereError {
            throw error
        } catch {
            throw .config(
                "cannot open --log-tsv \(path.path): \(error.localizedDescription)")
        }
    }

    /// One row, one line; `-` fills the columns an event doesn't carry. A
    /// value's control characters flatten to spaces, so no value can split or
    /// forge a row.
    func log(
        event: String, exit: String = "-", status: String = "-",
        bytes: String = "-", ms: String = "-", url: String = "-"
    ) {
        let columns = [
            Date().formatted(.iso8601), event, exit, status, bytes, ms, url,
        ].map(Self.flattened)
        handle.withLock { $0.write(Data((columns.joined(separator: "\t") + "\n").utf8)) }
    }

    /// `CharacterSet.controlCharacters` (Cc: C0, DEL, C1 — tab, CR, LF among
    /// them) become spaces: one line per row is the sink's invariant.
    private static func flattened(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
    }
}
