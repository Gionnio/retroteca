import Foundation
import CoreFoundation

/// A Mac app nxnative built (by Retroteca, another front end or by hand): what its Info.plist says.
public struct NXApp: Equatable, Sendable {
    public let url: URL
    public let titleID: String
    public let bundleID: String
    public let name: String
    public let version: String?
    public let engineCommit: String?

    public init?(url: URL) {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let titleID = info["DMTitleID"] as? String, let bundleID = info["CFBundleIdentifier"] as? String else { return nil }
        self.url = url
        self.titleID = titleID.uppercased()
        self.bundleID = bundleID
        name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        version = info["CFBundleShortVersionString"] as? String
        engineCommit = info["DMCommit"] as? String
    }

    var resources: URL { url.appendingPathComponent("Contents/Resources/dm") }

    /// The game's settings list (docs/frontends.md, "The settings list").
    public var launcherSettings: [NXSetting] {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("launcher.json")),
              let file = try? JSONDecoder().decode(NXSettingsFile.self, from: data) else { return [] }
        return file.settings
    }

    /// The main module's build ID, which names the game's cheat files (first 16 hex digits, upper case).
    public var cheatBuildID: String? {
        guard let handle = try? FileHandle(forReadingFrom: resources.appendingPathComponent("main.changed.tsv")),
              let head = try? handle.read(upToCount: 256) else { return nil }
        try? handle.close()
        for line in String(decoding: head, as: UTF8.self).split(separator: "\n") where line.hasPrefix("# BUILD_ID") {
            if let id = line.split(separator: "\t").last, id.count >= 16 { return String(id.prefix(16)).uppercased() }
        }
        return nil
    }

    /// nxnative apps in these folders (and one level of subfolders).
    public static func scan(_ folders: [URL]) -> [NXApp] {
        let fm = FileManager.default
        var found: [NXApp] = []
        for folder in folders {
            let level1 = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for item in level1 {
                if item.pathExtension == "app" {
                    if let app = NXApp(url: item) { found.append(app) }
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    for inner in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] where inner.pathExtension == "app" {
                        if let app = NXApp(url: inner) { found.append(app) }
                    }
                }
            }
        }
        return found
    }
}

struct NXSettingsFile: Decodable { let settings: [NXSetting] }

/// One row of `launcher.json`.
public struct NXSetting: Decodable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Decodable, Sendable { case choice, range, toggle }
    public let env: String
    public let kind: Kind
    public let section: String
    public let label: String
    public let note: String?
    public let `default`: String
    public let options: [[String]]?
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let on: String?
    public let off: String?
    public let level: String?
    public let needs: String?
    public var id: String { env }

    public var onValue: String { on ?? "1" }
    public var offValue: String { off ?? "0" }

    /// "DM_RUMBLE=1" → shown only while that setting has that value.
    public func isShown(values: [String: String]) -> Bool {
        guard let needs, let equal = needs.firstIndex(of: "=") else { return true }
        let key = String(needs[..<equal]), value = String(needs[needs.index(after: equal)...])
        guard let current = values[key] else { return true }
        return current == value
    }
}

/// The player's choices of one game, in the app's own preferences domain (`launcher.<env>`), the store its launcher reads
/// at every start: a choice equal to the tested default is removed, so a later build's defaults reach the player.
public struct NXSavedChoices: Sendable {
    public let bundleID: String

    public init(bundleID: String) { self.bundleID = bundleID }

    public func value(_ env: String) -> String? {
        CFPreferencesAppSynchronize(bundleID as CFString)
        return CFPreferencesCopyAppValue("launcher.\(env)" as CFString, bundleID as CFString) as? String
    }

    public func set(_ setting: NXSetting, to value: String) {
        let key = "launcher.\(setting.env)" as CFString
        CFPreferencesSetAppValue(key, value == setting.default ? nil : value as CFString, bundleID as CFString)
        CFPreferencesAppSynchronize(bundleID as CFString)
    }

    public func reset(_ settings: [NXSetting]) {
        for setting in settings { CFPreferencesSetAppValue("launcher.\(setting.env)" as CFString, nil, bundleID as CFString) }
        CFPreferencesAppSynchronize(bundleID as CFString)
    }

    /// The iCloud Drive folder the game's save syncs through (docs/frontends.md, "The cloud saves folder").
    public var cloudFolder: String? {
        get {
            CFPreferencesAppSynchronize(bundleID as CFString)
            let value = CFPreferencesCopyAppValue("cloudSaves.folder" as CFString, bundleID as CFString) as? String
            return value?.isEmpty == false ? value : nil
        }
        nonmutating set {
            CFPreferencesSetAppValue("cloudSaves.folder" as CFString, newValue.map { $0 as CFString }, bundleID as CFString)
            CFPreferencesAppSynchronize(bundleID as CFString)
        }
    }
}

/// `~/Library/Application Support/nxnative/<title ID>`: the game's env.txt, save, mods and cheats.
public struct NXGameFolder: Sendable {
    public let titleID: String
    public let root: URL

    public init(titleID: String, root: URL? = nil) {
        self.titleID = titleID
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? support.appendingPathComponent("nxnative/\(titleID)", isDirectory: true)
    }

    public var envFile: URL { root.appendingPathComponent("env.txt") }
    public var save: URL { root.appendingPathComponent("save", isDirectory: true) }
    public var mods: URL { root.appendingPathComponent("mods", isDirectory: true) }
    public var cheats: URL { root.appendingPathComponent("cheats", isDirectory: true) }

    // MARK: env.txt

    /// KEY=VALUE lines; the player's own lines are kept as they are.
    public func env() -> [String: String] {
        var values: [String: String] = [:]
        for line in ((try? String(contentsOf: envFile, encoding: .utf8)) ?? "").split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equal = trimmed.firstIndex(of: "=") else { continue }
            values[String(trimmed[..<equal])] = String(trimmed[trimmed.index(after: equal)...])
        }
        return values
    }

    /// Sets or removes one line, leaving the others untouched.
    public func setEnv(_ key: String, _ value: String?) throws {
        var lines = ((try? String(contentsOf: envFile, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + "=") }
        while lines.last == "" { lines.removeLast() }
        if let value { lines.append("\(key)=\(value)") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: envFile, atomically: true, encoding: .utf8)
    }
}

// MARK: - Mods

/// RomFS mods: one folder per mod in the game's `mods`, read top first through `DM_ROMFS_OVERLAY` (dm/host/hle_fs.c).
/// Code mods cannot work: nxnative recompiles the game's code when it builds the app.
public struct NXMods: Sendable {
    public struct Mod: Codable, Equatable, Identifiable, Sendable {
        public var folder: String
        public var isOn: Bool
        public var addedAt: Date
        public var source: String?
        public var id: String { folder }
    }

    public enum Failure: LocalizedError, Equatable {
        case noRomFS, codeMod, otherGame(String), severalRoots, tooLong
        public var errorDescription: String? {
            switch self {
            case .noRomFS: return "No romfs folder: only mods that change the game's files work."
            case .codeMod: return "This mod changes the game's code (exefs, IPS or pchtxt): it cannot work with a native build."
            case .otherGame(let id): return "This mod is for another game (\(id))."
            case .severalRoots: return "The archive holds several variants: unpack it and add the one you want."
            case .tooLong: return "Too many mods on at once for the engine's overlay line."
            }
        }
    }

    public let folder: NXGameFolder
    /// Retroteca's record of order and on/off: the folders are the truth for what exists.
    public let record: URL

    public init(folder: NXGameFolder, record: URL) {
        self.folder = folder
        self.record = record
    }

    /// Mods in overlay order (top wins), new folders found on disk appended, vanished ones dropped.
    public func list() -> [Mod] {
        let fm = FileManager.default
        let onDisk = ((try? fm.contentsOfDirectory(at: folder.mods, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !$0.lastPathComponent.hasPrefix(".") }
            .map(\.lastPathComponent)
        var mods = ((try? JSONDecoder().decode([Mod].self, from: Data(contentsOf: record))) ?? []).filter { onDisk.contains($0.folder) }
        for name in onDisk.sorted() where !mods.contains(where: { $0.folder == name }) {
            mods.append(Mod(folder: name, isOn: false, addedAt: Date(), source: nil))
        }
        return mods
    }

    /// Saves the order and writes the overlay line of the mods that are on.
    public func save(_ mods: [Mod]) throws {
        let line = mods.filter(\.isOn).map { folder.mods.appendingPathComponent($0.folder).path }.joined(separator: ":")
        guard line.utf8.count < 4000 else { throw Failure.tooLong }
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(mods).write(to: record)
        try folder.setEnv("DM_ROMFS_OVERLAY", line.isEmpty ? nil : line)
    }

    /// Pairs of mods that are on and change the same file: the upper one wins.
    public func conflicts(_ mods: [Mod]) -> [(upper: String, lower: String, files: Int)] {
        let active = mods.filter(\.isOn)
        let files = active.map { Set(Self.files(in: folder.mods.appendingPathComponent($0.folder))) }
        var result: [(String, String, Int)] = []
        for i in active.indices {
            for j in active.indices where j > i {
                let shared = files[i].intersection(files[j]).count
                if shared > 0 { result.append((active[i].folder, active[j].folder, shared)) }
            }
        }
        return result
    }

    static func files(in root: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var paths: [String] = []
        let base = root.standardizedFileURL.path
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            paths.append(String(url.standardizedFileURL.path.dropFirst(base.count)).lowercased())
        }
        return paths
    }

    /// The RomFS root inside an unpacked mod, refusing code mods and mods for another game.
    public static func romfsRoot(in folder: URL, titleID: String) throws -> URL {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { throw Failure.noRomFS }
        var roots: [URL] = []
        let codeNames: Set<String> = ["exefs", "exefs_patches", "main.npdm"]
        for case let url as URL in walker {
            let name = url.lastPathComponent.lowercased()
            if url.path.lowercased().contains("/cheats/") { continue }
            if codeNames.contains(name) || ["ips", "pchtxt"].contains(url.pathExtension.lowercased()) { throw Failure.codeMod }
            if name == "romfs", (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                roots.append(url)
                walker.skipDescendants()
            }
        }
        if folder.lastPathComponent.lowercased() == "romfs" { roots = [folder] }
        guard !roots.isEmpty else { throw Failure.noRomFS }
        guard roots.count == 1 else { throw Failure.severalRoots }
        // "atmosphere/contents/<TID>/romfs": the TID must be the game's (or its update's).
        for part in roots[0].pathComponents where part.count == 16 && UInt64(part, radix: 16) != nil {
            if SwitchTitle.baseID(of: part.uppercased()) != titleID.uppercased() { throw Failure.otherGame(part.uppercased()) }
        }
        return roots[0]
    }

    /// Adds a mod from a folder or an archive (.zip, .7z, .rar where the system can read it): its RomFS is copied into the game's mods.
    public func add(_ source: URL, titleID: String, name modName: String? = nil, label: String? = nil) throws -> Mod {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("retroteca-mod-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        var unpacked = source
        if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let tool = source.pathExtension.lowercased() == "zip" ? "/usr/bin/ditto" : "/usr/bin/tar"
            let arguments = tool == "/usr/bin/ditto" ? ["-x", "-k", source.path, work.path] : ["-xf", source.path, "-C", work.path]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
            unpacked = work
        }
        let root = try Self.romfsRoot(in: unpacked, titleID: titleID)
        var name = (modName ?? source.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        if name.lowercased() == "romfs" { name = source.deletingLastPathComponent().lastPathComponent }
        var candidate = name, n = 2
        while fm.fileExists(atPath: folder.mods.appendingPathComponent(candidate).path) { candidate = "\(name) \(n)"; n += 1 }
        try fm.createDirectory(at: folder.mods, withIntermediateDirectories: true)
        try fm.copyItem(at: root, to: folder.mods.appendingPathComponent(candidate))
        var mods = list()
        mods.removeAll { $0.folder == candidate }
        let mod = Mod(folder: candidate, isOn: true, addedAt: Date(), source: label ?? source.lastPathComponent)
        mods.insert(mod, at: 0)
        try save(mods)
        return mod
    }

    /// Moves a mod's folder to the Trash.
    public func remove(_ mod: Mod) throws {
        try FileManager.default.trashItem(at: folder.mods.appendingPathComponent(mod.folder), resultingItemURL: nil)
        try save(list().filter { $0.folder != mod.folder })
    }
}

// MARK: - Cheats

/// Atmosphère cheat files for the built game (docs/frontends.md, "Cheats"): `<build ID>.txt`, the cheats that are on in
/// `<build ID>.enabled`, and `.cheats-off-<title ID>` as the master switch. Written only while the game is closed.
public struct NXCheats: Sendable {
    public struct Cheat: Equatable, Identifiable, Sendable {
        public let name: String
        public let isMaster: Bool
        public var isOn: Bool
        public var id: String { name }
    }

    public let folder: NXGameFolder
    public let buildID: String

    public init(folder: NXGameFolder, buildID: String) {
        self.folder = folder
        self.buildID = buildID
    }

    public var file: URL { folder.cheats.appendingPathComponent("\(buildID).txt") }
    var enabledFile: URL { folder.cheats.appendingPathComponent("\(buildID).enabled") }
    var offFile: URL { folder.cheats.appendingPathComponent(".cheats-off-\(folder.titleID)") }

    public var masterOn: Bool {
        get { !FileManager.default.fileExists(atPath: offFile.path) }
        nonmutating set {
            if newValue { try? FileManager.default.removeItem(at: offFile) }
            else { try? FileManager.default.createDirectory(at: folder.cheats, withIntermediateDirectories: true); FileManager.default.createFile(atPath: offFile.path, contents: Data()) }
        }
    }

    /// Names as the engine counts them: a repeated name becomes "Name #2", "Name #3".
    public static func parse(_ text: String, enabled: Set<String>) -> [Cheat] {
        var cheats: [Cheat] = []
        var seen: [String: Int] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let isMaster = line.hasPrefix("{") && line.hasSuffix("}")
            guard (line.hasPrefix("[") && line.hasSuffix("]")) || isMaster else { continue }
            var name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            seen[name, default: 0] += 1
            if let count = seen[name], count > 1 { name += " #\(count)" }
            cheats.append(Cheat(name: name, isMaster: isMaster, isOn: isMaster || enabled.contains(name)))
        }
        return cheats
    }

    public func list() -> [Cheat] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let enabled = Set(((try? String(contentsOf: enabledFile, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        return Self.parse(text, enabled: enabled)
    }

    public func save(_ cheats: [Cheat]) throws {
        try FileManager.default.createDirectory(at: folder.cheats, withIntermediateDirectories: true)
        let names = cheats.filter { $0.isOn && !$0.isMaster }.map(\.name)
        try (names.joined(separator: "\n") + (names.isEmpty ? "" : "\n")).write(to: enabledFile, atomically: true, encoding: .utf8)
    }

    /// Imports a cheat file for this build; new cheats start off. A file named for another build is refused.
    public func importFile(_ source: URL) throws {
        let stem = source.deletingPathExtension().lastPathComponent.uppercased()
        if stem.count == 16, UInt64(stem, radix: 16) != nil, stem != buildID { throw Failure.otherBuild(stem) }
        let text = try String(contentsOf: source, encoding: .utf8)
        guard !Self.parse(text, enabled: []).isEmpty else { throw Failure.notCheats }
        try FileManager.default.createDirectory(at: folder.cheats, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: enabledFile)
    }

    public enum Failure: LocalizedError, Equatable {
        case otherBuild(String), notCheats
        public var errorDescription: String? {
            switch self {
            case .otherBuild(let id): return "These cheats are for build \(id), not this one."
            case .notCheats: return "No cheats found in this file."
            }
        }
    }
}

// MARK: - Saves

/// The game's save (`save/`, and `save_device` when the game has one): dated backups, restore and import.
public struct NXSaves: Sendable {
    public let folder: NXGameFolder
    public let backups: URL

    public init(folder: NXGameFolder, backups: URL) {
        self.folder = folder
        self.backups = backups
    }

    var parts: [String] { ["save", "save_device"] }

    public var lastModified: Date? {
        parts.compactMap { part in
            NXMods.files(in: folder.root.appendingPathComponent(part)).compactMap { rel in
                try? folder.root.appendingPathComponent(part + rel).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }.max()
        }.max()
    }

    public var size: Int64 {
        parts.reduce(0) { sum, part in
            sum + NXMods.files(in: folder.root.appendingPathComponent(part)).reduce(Int64(0)) { inner, rel in
                inner + Int64((try? folder.root.appendingPathComponent(part + rel).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
    }

    public var hasSave: Bool { FileManager.default.fileExists(atPath: folder.save.path) }

    /// Dated copies, newest first.
    public func list() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Copies `save` (and `save_device`) into a dated folder.
    @discardableResult
    public func backUp(note: String? = nil) throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let destination = backups.appendingPathComponent(formatter.string(from: Date()) + (note.map { " \($0)" } ?? ""), isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for part in parts where fm.fileExists(atPath: folder.root.appendingPathComponent(part).path) {
            try fm.copyItem(at: folder.root.appendingPathComponent(part), to: destination.appendingPathComponent(part))
        }
        return destination
    }

    /// Puts a backup back, after backing up what is there now.
    public func restore(_ backup: URL) throws {
        try backUp(note: "before restore")
        let fm = FileManager.default
        for part in parts {
            let source = backup.appendingPathComponent(part)
            let target = folder.root.appendingPathComponent(part)
            guard fm.fileExists(atPath: source.path) else { continue }
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
        }
    }

    /// Imports a save folder: Ryujinx's numbered folder (its committed `0`), or any folder holding the save's files.
    public func importFolder(_ source: URL) throws {
        let fm = FileManager.default
        let committed = source.appendingPathComponent("0", isDirectory: true)
        let from = fm.fileExists(atPath: committed.path) ? committed : source
        guard !NXMods.files(in: from).isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        if hasSave { try backUp(note: "before import") }
        try fm.createDirectory(at: folder.root, withIntermediateDirectories: true)
        if fm.fileExists(atPath: folder.save.path) { try fm.removeItem(at: folder.save) }
        try fm.copyItem(at: from, to: folder.save)
    }
}
