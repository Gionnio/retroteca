import Foundation

/// Bytes on disk the way APFS holds them: `allocated` is what Finder and `du` count, `own` the part no clone shares.
/// The engine copies a game's data into its app as clones of the build folder's extraction, so the two count once.
public struct SpaceSize: Equatable, Sendable {
    public var allocated: Int64
    public var own: Int64

    public init(allocated: Int64 = 0, own: Int64 = 0) {
        self.allocated = allocated
        self.own = own
    }

    public static let zero = SpaceSize()

    public static func + (a: SpaceSize, b: SpaceSize) -> SpaceSize {
        SpaceSize(allocated: a.allocated + b.allocated, own: a.own + b.own)
    }

    /// Shared with a clone elsewhere: stays on disk while that clone does.
    public var shared: Int64 { max(0, allocated - own) }
}

public enum DiskSpace {
    /// A file or a whole folder, without following links. Missing = zero.
    public static func measure(_ url: URL) -> SpaceSize {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .zero }
        if (info.st_mode & S_IFMT) == S_IFREG { return file(url.path) }
        guard (info.st_mode & S_IFMT) == S_IFDIR, let items = FileManager.default.enumerator(atPath: url.path) else { return .zero }
        var total = SpaceSize.zero
        while let relative = items.nextObject() as? String {
            let path = url.path + "/" + relative
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            total = total + file(path)
        }
        return total
    }

    /// One regular file: allocated size and APFS private size (ATTR_CMNEXT_PRIVATESIZE).
    static func file(_ path: String) -> SpaceSize {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 128)
        guard getattrlist(path, &list, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) == 0 else { return .zero }
        return buffer.withUnsafeBytes { raw in
            // Layout: length (4), returned attribute set, then the values in attribute-group order: file, then extended.
            var offset = 4 + MemoryLayout<attribute_set_t>.size
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            var allocated: Int64 = 0
            if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                allocated = raw.loadUnaligned(fromByteOffset: offset, as: Int64.self)
                offset += 8
            }
            // Not on APFS (or no answer): nothing is shared.
            let own = returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0
                ? raw.loadUnaligned(fromByteOffset: offset, as: Int64.self) : allocated
            return SpaceSize(allocated: allocated, own: own)
        }
    }

    /// Free space for the user's files on the volume holding `url` (what macOS can free for an important write).
    public static func free(at url: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    public static func capacity(at url: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity ?? 0)
    }
}

/// A built Switch game's footprint: its app, and its build folder split by what freeing the caches removes.
public struct GameSpace: Equatable, Sendable {
    public var app: SpaceSize
    /// The shader libraries and compile caches (`shader/`).
    public var shaders: SpaceSize
    /// Everything else the next build reuses: pipeline caches, extraction, patched code.
    public var otherCaches: SpaceSize
    /// What the engine no longer uses (`obsolete/`).
    public var leftovers: SpaceSize

    public init(app: SpaceSize = .zero, shaders: SpaceSize = .zero, otherCaches: SpaceSize = .zero, leftovers: SpaceSize = .zero) {
        self.app = app
        self.shaders = shaders
        self.otherCaches = otherCaches
        self.leftovers = leftovers
    }

    /// What the game really takes: the app, plus what the build folder does not share with it.
    public var total: Int64 { app.allocated + shaders.own + otherCaches.own + leftovers.own }
    /// What "free the caches" gives back.
    public var freeable: Int64 { shaders.own + otherCaches.own + leftovers.own }
    public var caches: Int64 { shaders.own + otherCaches.own }
}

/// A game's build folder (`NX/work/<title ID>`): what freeing its caches deletes and what it keeps.
public enum BuildFolder {
    /// Kept when the caches go: the provisional profile of a game the engine has none for, and the build logs.
    public static let kept: Set<String> = ["profile", "logs"]

    public static func measure(_ folder: URL, app: URL?) -> GameSpace {
        var space = GameSpace(app: app.map(DiskSpace.measure) ?? .zero)
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in items where !kept.contains(item.lastPathComponent) {
            switch item.lastPathComponent {
            case "shader": space.shaders = DiskSpace.measure(item)
            case "obsolete": space.leftovers = DiskSpace.measure(item)
            default: space.otherCaches = space.otherCaches + DiskSpace.measure(item)
            }
        }
        return space
    }

    /// The items freeing the caches deletes.
    public static func cacheItems(_ folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { !kept.contains($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Deletes the caches; returns the bytes given back (own bytes: shared ones stay with the app).
    /// `shaders` and `others` pick the shader caches and the rest; what the engine no longer uses always goes.
    @discardableResult
    public static func freeCaches(_ folder: URL, shaders: Bool = true, others: Bool = true) -> Int64 {
        var freed: Int64 = 0
        for item in cacheItems(folder) {
            let name = item.lastPathComponent
            guard name == "obsolete" || (name == "shader" ? shaders : others) else { continue }
            let size = DiskSpace.measure(item).own
            if (try? FileManager.default.removeItem(at: item)) != nil { freed += size }
        }
        return freed
    }
}

/// What a copy must match: how many files a folder holds and their bytes (logical sizes, links not followed).
public struct FolderSummary: Equatable, Sendable {
    public var files: Int
    public var bytes: Int64

    public static func of(_ url: URL) -> FolderSummary {
        var summary = FolderSummary(files: 0, bytes: 0)
        guard let items = FileManager.default.enumerator(atPath: url.path) else { return summary }
        var info = stat()
        while let relative = items.nextObject() as? String {
            guard lstat(url.path + "/" + relative, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            summary.files += 1
            summary.bytes += Int64(info.st_size)
        }
        return summary
    }
}
