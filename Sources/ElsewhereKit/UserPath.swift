public import Foundation

/// A path from a flag, an environment variable or a host's JSON config — none of
/// which a shell expanded: a leading `~` means the home directory
/// (`NSString.expandingTildeInPath`; `~user` included).
public enum UserPath {
    public static func expanded(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    public static func url(_ path: String) -> URL {
        URL(fileURLWithPath: expanded(path))
    }
}
