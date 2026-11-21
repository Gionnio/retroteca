import Foundation

/// `catalog/game-tweaks.json`: values Retroteca recommends for a game's native build, each one a setting of the
/// official engine with the note that backs it. A newer copy may come from the project's repository.
public struct GameTweaksCatalog: Codable, Equatable, Sendable {
    public struct Tweak: Codable, Equatable, Sendable, Identifiable {
        public let variable: String
        public let value: String
        public let why: [String: String]
        public let source: URL?
        /// Not part of "apply all": a trade-off the player picks on purpose.
        public let optional: Bool?
        /// Chip families the value is for ("M1"), or must not be offered on; measured per family, as costs differ a lot.
        public let onlyOn: [String]?
        public let avoidOn: [String]?
        /// Date of the engine commit that brought the value ("2026-11-15"): an older engine has the setting but not its effect.
        public let engineSince: String?

        public init(variable: String, value: String, why: [String: String], source: URL?, optional: Bool? = nil,
                    onlyOn: [String]? = nil, avoidOn: [String]? = nil, engineSince: String? = nil) {
            self.variable = variable
            self.value = value
            self.why = why
            self.source = source
            self.optional = optional
            self.onlyOn = onlyOn
            self.avoidOn = avoidOn
            self.engineSince = engineSince
        }

        /// Whether the value is meant for a Mac with this chip family (nil = unknown: only values without a chip rule)
        /// and for the engine in use, by its commit date (nil = unknown: only values without engineSince).
        public func fits(chip family: String?, engineDate: String? = nil) -> Bool {
            if let since = engineSince, (engineDate ?? "") < since { return false }
            if let only = onlyOn, !only.isEmpty { return family.map(only.contains) ?? false }
            if let avoid = avoidOn, let family, avoid.contains(family) { return false }
            return true
        }

        public var id: String { variable }
        public var isOptional: Bool { optional ?? false }

        /// The reason in the user's language, English otherwise.
        public func reason(language: String?) -> String {
            language.flatMap { why[$0] } ?? why["en"] ?? why.values.first ?? ""
        }
    }

    public struct GameEntry: Codable, Equatable, Sendable {
        public let titleID: String
        public let title: String
        public let engine: String
        public let checkedCommit: String
        public let settings: [Tweak]
    }

    public let version: String
    public let games: [GameEntry]

    public static func load(from url: URL) throws -> GameTweaksCatalog {
        try JSONDecoder().decode(GameTweaksCatalog.self, from: Data(contentsOf: url))
    }

    public func entry(titleID: String) -> GameEntry? {
        games.first { $0.titleID.caseInsensitiveCompare(titleID) == .orderedSame }
    }

    /// The newer of two copies (versions are dates, "2026-11-12").
    public static func newest(_ a: GameTweaksCatalog?, _ b: GameTweaksCatalog?) -> GameTweaksCatalog? {
        guard let a else { return b }
        guard let b else { return a }
        return b.version > a.version ? b : a
    }
}

/// Where a recommended value lives: a choice the game's launcher offers, or a line of the game's env.txt.
public enum TweakTarget: Equatable, Sendable {
    case launcher
    case env
}

public enum GameTweaks {
    /// "Apple M1 Pro" → "M1": the chip family a recommendation is measured on.
    public static func chipFamily(_ brand: String) -> String? {
        let parts: [Substring] = brand.split(separator: Character(" "))
        let family = parts.first { part in
            part.count >= 2 && part.first == "M" && part.dropFirst().allSatisfy(\.isNumber)
        }
        return family.map(String.init)
    }

    /// This Mac's chip family, from the processor's name.
    public static var currentChipFamily: String? {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return chipFamily(String(cString: buffer))
    }

    /// `docs/env_switches.tsv` of the engine: name → class (player, switch, diagnostic).
    public static func envSwitches(_ tsv: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in tsv.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: Character("\t"), maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count >= 2, columns[0].hasPrefix("DM_") else { continue }
            result[String(columns[0])] = String(columns[1])
        }
        return result
    }

    /// Where a tweak goes for this build, or nil when the engine has no such setting (never a diagnostic switch).
    public static func target(of tweak: GameTweaksCatalog.Tweak, launcher: Set<String>, switches: [String: String]) -> TweakTarget? {
        if launcher.contains(tweak.variable) { return .launcher }
        if let kind = switches[tweak.variable], kind == "player" || kind == "switch" { return .env }
        return nil
    }
}
