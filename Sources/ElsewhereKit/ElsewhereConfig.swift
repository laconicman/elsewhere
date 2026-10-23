public import Foundation

/// The one secret-bearing file (§5.2): `~/Library/Application Support/elsewhere/config.json`,
/// mode 0600. `direct` is implicit and never listed here; `env` is synthesized from
/// `ELSEWHERE_LINK` and never written to disk.
public struct ElsewhereConfig: Codable, Sendable, Equatable {
    /// Schema version. 1 today; bump when the shape changes so old binaries fail loudly.
    public var version: Int
    /// The exit used when none is named. Optional: a fresh file has no exits at all.
    public var `default`: String?
    /// Outbound socket binding, applied to every outbound including `direct` (§3.3).
    public var bindInterface: BindInterface
    /// The `User-Agent` a fetch sends (D8 — a browser's UA is the owner's decision).
    public var userAgent: UserAgent
    /// Named exits keyed by `ExitName`-validated names.
    public var exits: [String: Exit]

    public init(
        version: Int = 1,
        default: String? = nil,
        bindInterface: BindInterface = .auto,
        userAgent: UserAgent = .chrome,
        exits: [String: Exit] = [:]
    ) {
        self.version = version
        self.`default` = `default`
        self.bindInterface = bindInterface
        self.userAgent = userAgent
        self.exits = exits
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        `default` = try container.decodeIfPresent(String.self, forKey: .default)
        bindInterface = try container.decodeIfPresent(BindInterface.self, forKey: .bindInterface) ?? .auto
        userAgent = try container.decodeIfPresent(UserAgent.self, forKey: .userAgent) ?? .chrome
        exits = try container.decodeIfPresent([String: Exit].self, forKey: .exits) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        // encodeIfPresent: an unset default leaves no "default" key in the file —
        // the decoder tolerates absence, and a null reads as a value to a hand-editor.
        try container.encodeIfPresent(`default`, forKey: .default)
        try container.encode(bindInterface, forKey: .bindInterface)
        try container.encode(userAgent, forKey: .userAgent)
        try container.encode(exits, forKey: .exits)
    }

    enum CodingKeys: String, CodingKey {
        case version, `default`, bindInterface, userAgent, exits
    }
}

/// One exit's definition — exactly one of the three kinds (§5.2). A link is converted
/// through `XrayCore` at tunnel start and never stored converted; `xray` is a raw
/// outbound object for what links cannot express; `proxy` is an external local proxy
/// (INCY) used as an exit with no Xray involved.
public enum Exit: Sendable, Equatable {
    case link(String)
    case xray(JSONValue)
    case proxy(URL)
}

extension Exit: Codable {
    enum CodingKeys: String, CodingKey {
        case link, xray, proxy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let present = [CodingKeys.link, .xray, .proxy].filter { container.contains($0) }
        guard present.count == 1 else {
            let found = present.isEmpty
                ? "none"
                : present.map(\.rawValue).sorted().joined(separator: ", ")
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription:
                    "exit needs exactly one of 'link', 'xray', 'proxy'; found \(found)"))
        }
        switch present[0] {
        case .link: self = .link(try container.decode(String.self, forKey: .link))
        case .xray: self = .xray(try container.decode(JSONValue.self, forKey: .xray))
        case .proxy: self = .proxy(try container.decode(URL.self, forKey: .proxy))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .link(let link): try container.encode(link, forKey: .link)
        case .xray(let value): try container.encode(value, forKey: .xray)
        case .proxy(let url): try container.encode(url, forKey: .proxy)
        }
    }
}

/// Whether Xray's outbound sockets bind to a physical interface (§3.3). `auto` resolves
/// the current path's first physical interface at tunnel start; `none` disables binding
/// (`--via-system`); `named` pins one. Encoded as the strings `"auto"`, `"none"`, or the
/// interface name.
public enum BindInterface: Sendable, Hashable {
    case auto
    case none
    case named(String)
}

extension BindInterface: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "auto": self = .auto
        case "none": self = .none
        case let name: self = .named(name)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto: try container.encode("auto")
        case .none: try container.encode("none")
        case .named(let name): try container.encode(name)
        }
    }
}

/// The `User-Agent` sent on fetches. Encoded as `"chrome"` or the custom string.
/// D8: a browser's UA is the owner's decision — no JA3 spoofing, the header only.
public enum UserAgent: Sendable, Hashable {
    case chrome
    case custom(String)

    /// The current Chrome-on-macOS UA string. Chrome's UA-reduction freeze pins the
    /// build to `0.0.0` and the OS token to `10_15_7`, so only the major version moves.
    /// Stable on 2026-10-23 is 156.0.8078.48:
    /// <https://chromereleases.googleblog.com/2026/10/> (M-156 rolled out 2026-10-20).
    /// One named constant, hand-bumped per release — TechDebt TD-1.
    public static let chromeString =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36"
}

extension UserAgent: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "chrome": self = .chrome
        case let custom: self = .custom(custom)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .chrome: try container.encode("chrome")
        case .custom(let custom): try container.encode(custom)
        }
    }
}
