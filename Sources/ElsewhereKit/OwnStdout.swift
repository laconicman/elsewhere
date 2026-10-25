public import Foundation // FileHandle is public API
import Synchronization

/// The process's own stdout, claimed before the engine can write to descriptor 1.
///
/// Xray-core prints deprecation warnings at config-parse time through its *default* log
/// handler — Go's `log` on stdout — before the config's `log` block (silent, or a file)
/// is installed, so `test` and `run` can both put lines on fd 1 that no `loglevel`
/// silences (observed 2026-10-25 with a `ws`+`tls` outbound: two `[Warning]
/// common/errors` lines between MCP frames). stdout is `fetch`'s payload and `serve`'s
/// protocol, so the process keeps a duplicate of the original descriptor for everything
/// it prints and points fd 1 at a sink — `/dev/null`, or the engine log once that path
/// is known — for everything the engine prints.
public enum OwnStdout {
    private static let claimed = Mutex<FileHandle?>(nil)

    /// Where Elsewhere writes: the duplicated original stdout after ``claim()``, plain
    /// `FileHandle.standardOutput` before it (tests never claim — the runner's output
    /// stays visible).
    public static var handle: FileHandle {
        claimed.withLock { $0 } ?? .standardOutput
    }

    /// Duplicates fd 1 into ``handle`` and points fd 1 at `/dev/null`. Call once, when a
    /// real command starts running and before any engine or output call — not at parse:
    /// ArgumentParser's `--help` parses into a command whose `run()` prints on fd 1. A
    /// second call is a no-op.
    public static func claim() throws(ElsewhereError) {
        try claimed.withLock { (slot) throws(ElsewhereError) in
            guard slot == nil else { return }
            let copy = dup(STDOUT_FILENO)
            guard copy >= 0 else { throw .config("cannot duplicate stdout: \(errnoText())") }
            slot = FileHandle(fileDescriptor: copy, closeOnDealloc: false)
        }
        try sink(to: "/dev/null")
    }

    /// Points fd 1 at `path` (append, created 0600) — the engine log, so parse-time lines
    /// land beside the engine's own file log instead of in `/dev/null`.
    public static func sink(to path: String) throws(ElsewhereError) {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw .config("cannot open \(path) as the engine's stdout: \(errnoText())") }
        defer { close(fd) }
        guard dup2(fd, STDOUT_FILENO) >= 0 else {
            throw .config("cannot redirect stdout to \(path): \(errnoText())")
        }
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}
