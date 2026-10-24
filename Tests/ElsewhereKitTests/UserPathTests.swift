import ElsewhereKit
import Foundation
import Testing

/// UserPath: a leading `~` expands to the home directory — the expansion a
/// host's JSON config or an environment variable cannot do for a path value.
/// Absolute and relative paths pass through untouched.
@Suite("UserPath — a leading ~ means home")
struct UserPathTests {
    @Test func aTildeExpandsToHome() {
        #expect(
            UserPath.url("~/x").standardizedFileURL.path
                == FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: "x").standardizedFileURL.path)
    }

    @Test func anAbsolutePathIsUnchanged() {
        #expect(UserPath.url("/abs/x").path == "/abs/x")
    }

    @Test func aRelativePathResolvesLikePlainFileURL() {
        #expect(UserPath.url("rel") == URL(fileURLWithPath: "rel"))
    }
}
