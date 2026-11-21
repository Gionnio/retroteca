import Foundation

/// Where Switch games are built and kept: on this Mac, or on an external disk the user picked.
/// On a disk, apps go in `<disk>/Retroteca/` and builds in `<disk>/Retroteca/.retroteca-build/<title ID>`, on the same
/// volume so the engine can clone the game's data into the app. Saves always stay on the Mac.
public enum GamesLocation {
    /// The chosen disk's mount point ("/Volumes/T7"); none = this Mac.
    public static let key = "gamesVolume"

    public static var volume: URL? {
        UserDefaults.standard.string(forKey: key).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public static func choose(_ volume: URL?) {
        if let volume { UserDefaults.standard.set(volume.path, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// The chosen disk is connected (or no disk was chosen).
    public static var isAvailable: Bool {
        guard let volume else { return true }
        return FileManager.default.fileExists(atPath: volume.path)
    }

    public static var macAppsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Retroteca", isDirectory: true)
    }

    public static func appsFolder(on volume: URL?) -> URL {
        volume.map { $0.appendingPathComponent("Retroteca", isDirectory: true) } ?? macAppsFolder
    }

    /// Builds on the disk; nil = the Mac's own folder under Application Support.
    public static func buildRoot(on volume: URL?) -> URL? {
        volume.map { $0.appendingPathComponent("Retroteca/.retroteca-build", isDirectory: true) }
    }

    /// An app Retroteca built: in the Mac's folder or in the Retroteca folder of any disk.
    public static func isRetrotecaApp(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(macAppsFolder.path + "/") { return true }
        let parts = url.standardizedFileURL.pathComponents
        return parts.count >= 5 && parts[1] == "Volumes" && parts[3] == "Retroteca"
    }

    /// The disk an app sits on when that disk is not connected ("T7"); nil when it is there or on the Mac.
    public static func missingVolume(of url: URL) -> String? {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return nil }
        return FileManager.default.fileExists(atPath: "/Volumes/\(parts[2])") ? nil : parts[2]
    }
}

/// A mounted volume and whether Switch games can be built and kept on it.
public struct GamesVolume: Identifiable, Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case suitable
        case unsuitable(Problem)
    }

    /// Why a disk cannot hold the games (the app words it).
    public enum Problem: Equatable, Sendable {
        case network, readOnly, macOSExtended, fat
        case format(String)
    }

    public let url: URL
    public let name: String
    /// "apfs", "hfs", "exfat", "msdos", "smbfs"…
    public let format: String
    public let isLocal: Bool
    public let isInternal: Bool
    public let isReadOnly: Bool
    public let free: Int64

    public var id: String { url.path }

    public init(url: URL, name: String, format: String, isLocal: Bool, isInternal: Bool, isReadOnly: Bool, free: Int64) {
        self.url = url
        self.name = name
        self.format = format
        self.isLocal = isLocal
        self.isInternal = isInternal
        self.isReadOnly = isReadOnly
        self.free = free
    }

    /// The engine needs APFS (clones, and an app that can be replaced) on a disk attached to the Mac.
    public var verdict: Verdict {
        if !isLocal { return .unsuitable(.network) }
        if isReadOnly { return .unsuitable(.readOnly) }
        switch format.lowercased() {
        case "apfs": return .suitable
        case "hfs": return .unsuitable(.macOSExtended)
        case "exfat", "msdos": return .unsuitable(.fat)
        default: return .unsuitable(.format(format))
        }
    }

    /// External disks attached to the Mac and network shares, as mounted now (the Mac's own disk is "Questo Mac").
    public static func mounted() -> [GamesVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTypeNameKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsReadOnlyKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false, values.volumeIsRootFileSystem != true, url.path.hasPrefix("/Volumes/") else { return nil }
            return GamesVolume(url: url, name: values.volumeName ?? url.lastPathComponent, format: values.volumeTypeName ?? "?",
                               isLocal: values.volumeIsLocal ?? false, isInternal: values.volumeIsInternal ?? false,
                               isReadOnly: values.volumeIsReadOnly ?? false, free: values.volumeAvailableCapacityForImportantUsage ?? 0)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
