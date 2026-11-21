import XCTest
@testable import RetrotecaCore
import Compression

final class PlatformCatalogTests: XCTestCase {
    /// The real catalog shipped with the app.
    static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("catalog/platforms.json")

    func testShippedCatalogLoads() throws {
        let catalog = try PlatformCatalog.load(from: Self.catalogURL)
        XCTAssertEqual(catalog.platforms.map(\.id), ["switch", "switch2"])
        XCTAssertEqual(Set(catalog.platforms.map(\.id)).count, catalog.platforms.count, "duplicate platform ids")
    }

    func testExtensionsAreUniqueToOnePlatform() throws {
        let catalog = try PlatformCatalog.load(from: Self.catalogURL)
        var owner: [String: String] = [:]
        for p in catalog.platforms {
            for ext in p.extensions {
                XCTAssertNil(owner[ext], "\(ext) belongs to \(owner[ext] ?? "") and \(p.id): move it to `shared`")
                owner[ext] = p.id
            }
        }
    }

    func testLookup() throws {
        let catalog = try PlatformCatalog.load(from: Self.catalogURL)
        XCTAssertEqual(catalog.platformID(forExtension: "NSP"), "switch")
        XCTAssertEqual(catalog.platformID(forExtension: "xcz"), "switch")
        XCTAssertEqual(catalog.platformID(forExtension: "nup"), "switch2")
        XCTAssertNil(catalog.platformID(forExtension: "iso"))
    }
}

final class TitleTests: XCTestCase {
    func testCleanTitle() {
        XCTAssertEqual(cleanTitle(fromFileName: "Super Mario World (USA) [!].sfc"), "Super Mario World")
        XCTAssertEqual(cleanTitle(fromFileName: "Metroid_Prime (Europe) (En,Fr,De).iso"), "Metroid Prime")
        XCTAssertEqual(cleanTitle(fromFileName: "Super Mario Bros. Wonder [010015100B514000][v0].nsp"), "Super Mario Bros. Wonder")
        XCTAssertEqual(cleanTitle(fromFileName: "(USA).gba"), "(USA)")
        XCTAssertEqual(cleanTitle(fromFileName: "Legend of Zelda, The - The Wind Waker (Europe).rvz"), "The Legend of Zelda - The Wind Waker")
        XCTAssertEqual(cleanTitle(fromFileName: "Simpsons, The (USA).nes"), "The Simpsons")
    }
}

final class LibraryTests: XCTestCase {
    private func game(_ title: String, platform: String? = "snes", kind: GameKind = .emulated, status: GameStatus = .ready,
                      favorite: Bool = false, played: Date? = nil) -> Game {
        Game(title: title, platformID: platform, kind: kind, files: [URL(fileURLWithPath: "/tmp/\(title)")],
             status: status, isFavorite: favorite, lastPlayedAt: played)
    }

    func testFiltersAndSorting() {
        let now = Date()
        let games = [
            game("Zelda", favorite: true, played: now.addingTimeInterval(-3600)),
            game("Alpha", status: .needsEngine),
            game("Mario", kind: .switchNative, played: now.addingTimeInterval(-60)),
            game("Old", played: now.addingTimeInterval(-40 * 24 * 3600)),
            game("Disc", platform: nil, status: .unrecognized),
        ]
        XCTAssertEqual(games.filtered(by: .all, now: now).map(\.title), ["Mario", "Zelda", "Old", "Alpha", "Disc"])
        XCTAssertEqual(games.filtered(by: .recent, now: now).map(\.title), ["Mario", "Zelda"])
        XCTAssertEqual(games.count(.favorites), 1)
        XCTAssertEqual(games.count(.toInstall), 1)
        XCTAssertEqual(games.count(.kind(.switchNative)), 1)
        XCTAssertEqual(games.count(.unrecognized), 1)
        XCTAssertEqual(games.filtered(by: .all, search: "zel").map(\.title), ["Zelda"])
    }

    func testStoreRoundTripAndDuplicates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(fileURL: dir.appendingPathComponent("library.json"))
        let a = game("A")
        XCTAssertEqual(store.add([a, game("B")]).count, 2)
        XCTAssertEqual(store.add([game("A")]).count, 0, "same file must not be added twice")
        try store.save()

        let reloaded = LibraryStore(fileURL: store.fileURL)
        try reloaded.load()
        XCTAssertEqual(reloaded.games.map(\.title), ["A", "B"])
        XCTAssertEqual(reloaded.games.first?.id, a.id)
    }

    func testMissingFilesComeAndGo() {
        let store = LibraryStore(fileURL: URL(fileURLWithPath: "/dev/null"))
        store.add([game("A", status: .needsEngine)])
        store.refreshFileStatus { _ in false }
        XCTAssertEqual(store.games[0].status, .missingFiles)
        store.refreshFileStatus { _ in true }
        XCTAssertEqual(store.games[0].status, .needsEngine)
    }
}

final class ImporterTests: XCTestCase {
    func testImportFolder() throws {
        let catalog = try PlatformCatalog.load(from: PlatformCatalogTests.catalogURL)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("PS1/FF9")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        func touch(_ path: String, _ text: String = "") throws {
            try text.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try touch("Super Mario World (USA).sfc")
        try touch("Wonder [010015100B514000][v0].nsp")
        try touch("Bananza.nup")
        try touch("readme.txt")
        try touch("Game.iso")
        try touch("PS1/FF9/Final Fantasy IX (Disc 1).cue", "FILE \"Final Fantasy IX (Disc 1).bin\" BINARY\n  TRACK 01 MODE2/2352\n")
        try touch("PS1/FF9/Final Fantasy IX (Disc 1).bin")

        let games = Importer(catalog: catalog).games(from: [dir])
        let byTitle = Dictionary(uniqueKeysWithValues: games.map { ($0.title, $0) })
        XCTAssertEqual(games.map(\.title).sorted(), ["Bananza", "Wonder"], "only Switch and Switch 2 files")
        XCTAssertEqual(byTitle["Wonder"]?.kind, .switchNative)
        XCTAssertEqual(byTitle["Wonder"]?.platformID, "switch")
        XCTAssertEqual(byTitle["Bananza"]?.platformID, "switch2")
        XCTAssertEqual(byTitle["Bananza"]?.status, .needsEngine)
    }
}

final class GameCopierTests: XCTestCase {
    func testCopiesOnceAndKeepsOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let rom = source.appendingPathComponent("Mario.sfc")
        try Data(repeating: 7, count: 2048).write(to: rom)
        let game = Game(title: "Mario", platformID: "snes", files: [rom], status: .needsEngine)

        let copier = GameCopier(destination: root.appendingPathComponent("Games"))
        let first = copier.copy([game])
        XCTAssertTrue(first.failures.isEmpty)
        XCTAssertEqual(first.games[0].files[0].path, root.appendingPathComponent("Games/snes/Mario.sfc").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rom.path), "the original stays")

        let second = copier.copy([game])
        XCTAssertTrue(second.failures.isEmpty, "same file again is not an error")

        try Data(repeating: 1, count: 10).write(to: rom)
        let third = copier.copy([game])
        XCTAssertEqual(third.failures.count, 1, "a different file with the same name is not overwritten")
        XCTAssertEqual(third.games[0].files[0], rom, "failed copies keep the original file")
    }
}

final class SwitchEngineTests: XCTestCase {
    func testTitleIDs() {
        let base = "Super Mario Bros. Wonder [010015100B514000][v0][US].xci"
        XCTAssertEqual(SwitchTitle.titleID(inFileName: base), "010015100B514000")
        XCTAssertEqual(SwitchTitle.version(inFileName: "Game [010015100B514800][v65536].nsp"), 65536)
        XCTAssertEqual(SwitchTitle.role(of: "010015100B514000"), .base)
        XCTAssertEqual(SwitchTitle.role(of: "010015100B514800"), .update)
        XCTAssertEqual(SwitchTitle.role(of: "010015100B515001"), .dlc)
        XCTAssertEqual(SwitchTitle.baseID(of: "010015100B514800"), "010015100B514000")
        XCTAssertEqual(SwitchTitle.baseID(of: "010015100B515001"), "010015100B514000")
        XCTAssertNil(SwitchTitle.titleID(inFileName: "Legend of Zelda, The - Tears of the Kingdom (World).xci"))
    }

    func testProfiles() {
        let list = "0100F2C0115B6000\t0100F2C0115B6000\tThe Legend of Zelda: Tears of the Kingdom\n010015100B514000\t010015100B514000\tSuper Mario Bros. Wonder\nnoise\n"
        let profiles = NXProfile.parseList(list)
        XCTAssertEqual(profiles.count, 2)
        let byName = NXProfile.match(titleID: nil, title: cleanTitle(fromFileName: "Legend of Zelda, The - Tears of the Kingdom (World) (En,Ja).xci"), in: profiles)
        XCTAssertEqual(byName?.titleID, "0100F2C0115B6000")
        XCTAssertEqual(NXProfile.match(titleID: "010015100B514800", title: "whatever", in: profiles)?.name, "Super Mario Bros. Wonder")
        XCTAssertNil(NXProfile.match(titleID: nil, title: "Tales of the Shire", in: profiles))
        let readme = "| Game | Title ID | Build |\n|---|---|---|\n| [Super Mario Bros. Wonder](010015100B514000/README.md) | `010015100B514000` | 1.2.1 (and 1.0.0) | 16.2.12 |\n"
        XCTAssertEqual(NXProfile.parseBuilds(readme: readme)["010015100B514000"], "1.2.1 (and 1.0.0)")
    }

    func testBuildEvents() {
        var state = NXBuildState()
        let lines = [
            #"{"ev": "stage", "k": 1, "n": 6, "name": "build nx_extract", "step": "", "t": 1}"#,
            #"{"ev": "stage_end", "k": 1, "name": "build nx_extract", "ok": true, "summary": "", "elapsed": 0.8, "t": 2}"#,
            #"{"ev": "stage", "k": 2, "n": 7, "name": "Mac shaders", "step": "", "t": 3}"#,
            #"{"ev": "progress", "k": 2, "name": "Mac shaders", "step": "compiling", "done": 119, "total": 28379, "unit": "shaders", "est": false, "note": "", "frac": 0.5, "eta": 30.0, "elapsed": 6.8, "t": 4}"#,
            #"{"ev": "game", "title_id": "010015100B514000", "name": "Super Mario Bros. Wonder", "version": "1.0.0", "bundle_id": "org.nxnative.010015100b514000", "out": "/tmp/W.app", "icon": null, "t": 5}"#,
            #"{"ev": "say", "msg": "[RED] the game has no it (Italian); its languages: en-US ja (--language / LANGUAGE)", "t": 6}"#,
            "not json",
        ]
        for line in lines { if let event = NXEvent.parse(line) { state.apply(event) } }
        XCTAssertEqual(state.stageCount, 7)
        XCTAssertEqual(state.stages.count, 2)
        XCTAssertTrue(state.stages[0].finished)
        XCTAssertEqual(state.stages[1].total, 28379)
        XCTAssertEqual(state.overallFraction, 1.5 / 7, accuracy: 0.001)
        XCTAssertEqual(state.gameName, "Super Mario Bros. Wonder")
        XCTAssertNil(state.icon)
        XCTAssertTrue(NXBuildCommand.failedOnLanguage(state))
    }

    func testShippedEngineCatalog() throws {
        let url = PlatformCatalogTests.catalogURL.deletingLastPathComponent().appendingPathComponent("native-engines.json")
        let catalog = try NativeEngineCatalog.load(from: url)
        let engine = try XCTUnwrap(catalog.engine(for: "switch"))
        XCTAssertEqual(engine.commit.count, 40)
        let paths = NXPaths(root: URL(fileURLWithPath: "/tmp/nx"))
        let args = NXBuildCommand.arguments(engine: engine, paths: paths, titleID: "010015100B514000", output: URL(fileURLWithPath: "/tmp/W.app"), language: "it", needsKeys: true)
        XCTAssertEqual(args.first, "/tmp/nx/nxnative/scripts/build_ipa_from_nsp.py")
        XCTAssertTrue(args.contains("mac-app") && args.contains("json") && args.contains("/tmp/nx/keys/prod.keys"))
        XCTAssertEqual(NXBuildCommand.language(for: Locale(identifier: "it_IT")), "it")
        XCTAssertNil(NXBuildCommand.language(for: Locale(identifier: "en_US")))
    }

    func testKeysImportPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("fake.keys")
        // Placeholder values only: the shape of the file, no real key.
        try (["header_key = 00"] + (0..<5).map { "test_key_\($0) = 00" }).joined(separator: "\n").write(to: fake, atomically: true, encoding: .utf8)
        let destination = dir.appendingPathComponent("NX/keys/prod.keys")
        try NXKeys.importKeys(from: fake, to: destination)
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let notKeys = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: notKeys, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try NXKeys.importKeys(from: notKeys, to: destination))
    }
}

final class SwitchGameDataTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("retroteca-nx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testStoreMetadataPicksOriginalEdition() {
        let json = """
        {"response":{"docs":[
         {"title":"Game – Nintendo Switch 2 Edition","dates_released_dts":["2026-03-26T00:00:00Z"],"image_url_h16x9_s":"https://x/ns2_image500w.jpg"},
         {"title":"Game","excerpt":"Short.","publisher":"Nintendo","dates_released_dts":["2023-10-20T00:00:00Z"],
          "pretty_game_categories_txt":["Azione"],"image_url_h2x1_s":"https://x/2x1_image500w.jpg","image_url_sq_s":"https://x/1x1_image500w.jpg"}]}}
        """
        let meta = SwitchMetadata.parse(Data(json.utf8))
        XCTAssertEqual(meta?.title, "Game")
        XCTAssertEqual(meta?.year, 2023)
        XCTAssertEqual(meta?.genres, ["Azione"])
        XCTAssertEqual(meta?.banner?.absoluteString, "https://x/2x1_image1600w.jpg")
        XCTAssertNil(SwitchMetadata.parse(Data(#"{"response":{"docs":[]}}"#.utf8)))
        XCTAssertTrue(SwitchMetadata.url(titleID: "010015100B514000", language: "it").absoluteString.contains("/it/select?fq=application_id_s:010015100b514000"))
    }

    func testEnvFileKeepsOtherLines() throws {
        let folder = NXGameFolder(titleID: "010015100B514000", root: dir)
        try "DM_FPS_TARGET=60\n# mine\n".write(to: folder.envFile, atomically: true, encoding: .utf8)
        try folder.setEnv("DM_ROMFS_OVERLAY", "/a:/b")
        XCTAssertEqual(folder.env()["DM_ROMFS_OVERLAY"], "/a:/b")
        XCTAssertEqual(folder.env()["DM_FPS_TARGET"], "60")
        try folder.setEnv("DM_ROMFS_OVERLAY", nil)
        XCTAssertNil(folder.env()["DM_ROMFS_OVERLAY"])
        XCTAssertTrue(try String(contentsOf: folder.envFile, encoding: .utf8).contains("# mine"))
    }

    func testModsImportOrderAndConflicts() throws {
        let folder = NXGameFolder(titleID: "010015100B514000", root: dir.appendingPathComponent("game"))
        let mods = NXMods(folder: folder, record: dir.appendingPathComponent("mods.json"))
        func makeMod(_ name: String, path: String) throws -> URL {
            let root = dir.appendingPathComponent("src/\(name)")
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
            return root
        }
        _ = try mods.add(try makeMod("Music", path: "romfs/Sound/a.bin"), titleID: "010015100B514000")
        _ = try mods.add(try makeMod("Atmo", path: "atmosphere/contents/010015100B514000/romfs/Sound/a.bin"), titleID: "010015100B514000")
        let list = mods.list()
        XCTAssertEqual(list.map(\.folder), ["Atmo", "Music"], "newest on top")
        XCTAssertEqual(mods.conflicts(list).first?.files, 1)
        XCTAssertTrue(folder.env()["DM_ROMFS_OVERLAY"]?.hasSuffix("/mods/Atmo:" + folder.mods.appendingPathComponent("Music").path) ?? false)
        XCTAssertThrowsError(try mods.add(try makeMod("Code", path: "exefs/main.npdm"), titleID: "010015100B514000"))
        XCTAssertThrowsError(try mods.add(try makeMod("Other", path: "atmosphere/contents/0100000000010000/romfs/x.bin"), titleID: "010015100B514000"))
        XCTAssertThrowsError(try mods.add(try makeMod("Nothing", path: "readme.txt"), titleID: "010015100B514000"))
    }

    func testCheatsParseAndEnable() throws {
        let folder = NXGameFolder(titleID: "010015100B514000", root: dir)
        let cheats = NXCheats(folder: folder, buildID: "CD6E42AEE7934F4D")
        let source = dir.appendingPathComponent("CD6E42AEE7934F4D.txt")
        try "{Master}\n04000000 0 0\n[Inf Lives]\n04000000 1 1\n[Coins]\n0400\n[Coins]\n0400\n".write(to: source, atomically: true, encoding: .utf8)
        try cheats.importFile(source)
        var list = cheats.list()
        XCTAssertEqual(list.map(\.name), ["Master", "Inf Lives", "Coins", "Coins #2"])
        XCTAssertFalse(list[1].isOn, "imported cheats start off")
        list[1].isOn = true
        try cheats.save(list)
        XCTAssertTrue(cheats.list()[1].isOn)
        cheats.masterOn = false
        XCTAssertFalse(cheats.masterOn)
        let wrong = dir.appendingPathComponent("0123456789ABCDEF.txt")
        try "[X]\n".write(to: wrong, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try cheats.importFile(wrong))
    }

    func testSavesBackupImportRestore() throws {
        let folder = NXGameFolder(titleID: "010015100B514000", root: dir.appendingPathComponent("game"))
        let saves = NXSaves(folder: folder, backups: dir.appendingPathComponent("backups"))
        let ryujinx = dir.appendingPathComponent("ryujinx/0000000000000001/0")
        try FileManager.default.createDirectory(at: ryujinx, withIntermediateDirectories: true)
        try Data("save-v1".utf8).write(to: ryujinx.appendingPathComponent("game_data.sav"))
        try saves.importFolder(ryujinx.deletingLastPathComponent())
        XCTAssertEqual(try String(contentsOf: folder.save.appendingPathComponent("game_data.sav"), encoding: .utf8), "save-v1")
        let backup = try saves.backUp()
        try Data("save-v2".utf8).write(to: folder.save.appendingPathComponent("game_data.sav"))
        try saves.restore(backup)
        XCTAssertEqual(try String(contentsOf: folder.save.appendingPathComponent("game_data.sav"), encoding: .utf8), "save-v1")
        XCTAssertEqual(saves.list().count, 2, "the restore kept a copy of what it replaced")
    }

    func testNXAppReadsInfoAndBuildID() throws {
        let app = dir.appendingPathComponent("Game.app")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        let info: NSDictionary = ["DMTitleID": "010015100B514000", "CFBundleIdentifier": "org.nxnative.010015100b514000", "CFBundleDisplayName": "Game", "CFBundleShortVersionString": "1.0.0"]
        info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try "# BUILD_ID\tcd6e42aee7934f4d8393cd43893ae25e\n0x1\t0x4\n".write(to: dm.appendingPathComponent("main.changed.tsv"), atomically: true, encoding: .utf8)
        try #"{"schema":1,"settings":[{"env":"DM_RUMBLE","kind":"toggle","section":"Controls","label":"Game rumble","default":"1","on":"1","off":"0","level":"basic"},{"env":"DM_RUMBLE_GAIN","kind":"range","section":"Controls","label":"Rumble strength","default":"1.0","min":0.0,"max":1.0,"step":0.05,"needs":"DM_RUMBLE=1"}]}"#
            .write(to: dm.appendingPathComponent("launcher.json"), atomically: true, encoding: .utf8)
        let parsed = try XCTUnwrap(NXApp(url: app))
        XCTAssertEqual(parsed.cheatBuildID, "CD6E42AEE7934F4D")
        XCTAssertEqual(parsed.launcherSettings.count, 2)
        XCTAssertFalse(parsed.launcherSettings[1].isShown(values: ["DM_RUMBLE": "0"]))
        XCTAssertEqual(NXApp.scan([dir]).map(\.titleID), ["010015100B514000"])
    }
}

final class ControllerMappingTests: XCTestCase {
    func testAssignMovesButtonBetweenActions() {
        var mapping = ControllerMapping.hidDefault(vendorID: 0x057E)
        XCTAssertEqual(mapping.action(for: .hid(2)), .select, "Nintendo confirms with A")
        XCTAssertEqual(mapping.action(for: .hid(1)), .back)
        mapping.assign(.hid(1), to: .select)
        XCTAssertEqual(mapping.action(for: .hid(1)), .select)
        XCTAssertNil(mapping.buttons[.back], "one button, one action")
        XCTAssertEqual(ControllerMapping.gameController.action(for: .gc("buttonA")), .select)
    }

    func testHatAndAxes() {
        XCTAssertTrue(HatDirection.vector(0) == (0, 1))
        XCTAssertTrue(HatDirection.vector(2) == (1, 0))
        XCTAssertTrue(HatDirection.vector(8) == (0, 0), "centred")
        XCTAssertTrue(HatDirection.vector(15, min: 0, max: 7) == (0, 0))
        XCTAssertTrue(HatDirection.vector(1, min: 0, max: 3) == (1, 0), "four-way hat")
        XCTAssertEqual(HatDirection.normalize(0, min: 0, max: 65535), -1, accuracy: 0.001)
        XCTAssertEqual(HatDirection.normalize(65535, min: 0, max: 65535), 1, accuracy: 0.001)
    }

    func testProfilesPersistPerPad() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "retroteca-test-\(UUID().uuidString)"))
        var profiles = ControllerProfiles()
        let key = ControllerProfiles.key(name: "Pro Controller", vendorID: 0x057E, productID: 0x2009)
        XCTAssertEqual(key, "Pro Controller 057E:2009")
        var mapping = ControllerMapping.hidDefault(vendorID: 0x057E)
        mapping.assign(.hid(3), to: .secondary)
        profiles.mappings[key] = mapping
        profiles.save(to: defaults)
        let loaded = ControllerProfiles.load(from: defaults)
        XCTAssertEqual(loaded.mapping(for: key, fallback: .gameController).action(for: .hid(3)), .secondary)
        XCTAssertEqual(loaded.mapping(for: "Other", fallback: .gameController), .gameController)
    }
}

final class SwitchUpdatesTests: XCTestCase {
    /// A PFS0 container like an update NSP: a ticket named after the rights ID and a plain cnmt.xml.
    private func makeNSP(_ names: [(String, Data)]) throws -> URL {
        var strings = Data(), entries = Data(), body = Data()
        for (name, content) in names {
            var entry = Data()
            entry.append(contentsOf: withUnsafeBytes(of: UInt64(body.count).littleEndian, Array.init))
            entry.append(contentsOf: withUnsafeBytes(of: UInt64(content.count).littleEndian, Array.init))
            entry.append(contentsOf: withUnsafeBytes(of: UInt32(strings.count).littleEndian, Array.init))
            entry.append(contentsOf: [0, 0, 0, 0])
            entries.append(entry)
            strings.append(Data(name.utf8)); strings.append(0)
            body.append(content)
        }
        var file = Data("PFS0".utf8)
        file.append(contentsOf: withUnsafeBytes(of: UInt32(names.count).littleEndian, Array.init))
        file.append(contentsOf: withUnsafeBytes(of: UInt32(strings.count).littleEndian, Array.init))
        file.append(contentsOf: [0, 0, 0, 0])
        file.append(entries); file.append(strings); file.append(body)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Donkey Kong Country Tropical Freeze Update \(UUID().uuidString.prefix(4)).nsp")
        try file.write(to: url)
        return url
    }

    func testPackageWithoutTitleIDInName() throws {
        let xml = "<ContentMeta><Type>Patch</Type><Id>0x0100c1f0051b6800</Id><Version>196608</Version></ContentMeta>"
        let url = try makeNSP([("0100c1f0051b68000000000000000004.tik", Data(repeating: 1, count: 64)),
                               ("abc.cnmt.xml", Data(xml.utf8)), ("f63b.nca", Data(repeating: 2, count: 32))])
        defer { try? FileManager.default.removeItem(at: url) }
        let package = try XCTUnwrap(SwitchPackage.read(url))
        XCTAssertEqual(package.titleIDs.first, "0100C1F0051B6800")
        XCTAssertEqual(package.version, 196608)
        let info = SwitchFileInfo.identify(url)
        XCTAssertEqual(info.role, .update)
        XCTAssertEqual(info.baseID, "0100C1F0051B6000")
    }

    func testNamesAndBaseTitles() {
        XCTAssertEqual(SwitchFileInfo.identify(URL(fileURLWithPath: "/x/Game Update.nsp"), readPackage: false).role, .update)
        XCTAssertEqual(SwitchFileInfo.identify(URL(fileURLWithPath: "/x/Game DLC Pack.nsp"), readPackage: false).role, .dlc)
        XCTAssertEqual(SwitchFileInfo.baseTitle("Donkey Kong Country Tropical Freeze Update v1.0.2.nsp"),
                       SwitchTitle.normalized("Donkey Kong Country: Tropical Freeze"))
        let base = SwitchFileInfo.identify(URL(fileURLWithPath: "/x/Game [0100A3501946E000][v0].nsp"), readPackage: false)
        XCTAssertEqual(base.role, .base)
        XCTAssertEqual(base.version, 0)
    }

    func testProfileVersions() {
        let tsv = "# comment\nbuild\tv0\t1.0.0\tmain=cd6e\nbuild\tv65536\t1.0.1\tmain=f918\nbuild\tv327680\t1.2.1\tmain=ff77\npackage\tv327680\n"
        let versions = NXProfileVersions.parse(tsv)
        XCTAssertEqual(versions.tested[327680], "1.2.1")
        XCTAssertEqual(versions.recommended, 327680)
        XCTAssertEqual(versions.choose(from: [0, 65536]), 65536, "newest tested when the recommended one is missing")
        XCTAssertEqual(versions.choose(from: [0, 327680, 400000]), 327680)
        XCTAssertEqual(NXProfileVersions().choose(from: [0, 131072]), 131072)
        let engine = NativeEngine(id: "nxnative", name: "nxnative", repo: "seedds/nxnative", license: "MIT", commit: String(repeating: "a", count: 40), committedAt: nil,
                                  platforms: ["switch"], requires: .init(macOS: "26.6", xcode: "27.2", python: "3.14", brew: [], casks: [], pythonRequirements: "r.txt"),
                                  script: "scripts/build_ipa_from_nsp.py", profiles: "dm/games", credit: nil, channels: nil)
        let args = NXBuildCommand.arguments(engine: engine, paths: NXPaths(root: URL(fileURLWithPath: "/tmp/nx")), titleID: "X", output: URL(fileURLWithPath: "/tmp/X.app"),
                                            language: nil, needsKeys: false, package: 65536)
        XCTAssertEqual(Array(args.suffix(2)), ["-p", "v65536"])
        let withIcon = NXBuildCommand.arguments(engine: engine, paths: NXPaths(root: URL(fileURLWithPath: "/tmp/nx")), titleID: "X", output: URL(fileURLWithPath: "/tmp/X.app"),
                                                language: nil, needsKeys: false, icon: URL(fileURLWithPath: "/tmp/cover.jpg"))
        XCTAssertEqual(Array(withIcon.suffix(2)), ["--icon", "/tmp/cover.jpg"])
        let fallback = NXBuildCommand.arguments(engine: engine, paths: NXPaths(root: URL(fileURLWithPath: "/tmp/nx")), titleID: "X", output: URL(fileURLWithPath: "/tmp/X.app"),
                                                language: nil, needsKeys: false, icon: URL(fileURLWithPath: "/tmp/cover.jpg"), iconIsFallback: true)
        XCTAssertEqual(Array(fallback.suffix(2)), ["--fallback-icon", "/tmp/cover.jpg"])
    }
}

final class GameBananaTests: XCTestCase {
    func testFitOfArchives() {
        XCTAssertEqual(GameBanana.fit(of: ["Mod/romfs/Pack/a.pack.zs"], titleID: "0100F2C0115B6000"), .works)
        XCTAssertEqual(GameBanana.fit(of: ["UltraCam/exefs/main.npdm", "UltraCam/romfs/a.ini"], titleID: "0100F2C0115B6000"), .codeMod)
        XCTAssertEqual(GameBanana.fit(of: ["x.pchtxt"], titleID: "0100F2C0115B6000"), .codeMod)
        XCTAssertEqual(GameBanana.fit(of: ["atmosphere/contents/01007EF00011E000/romfs/a"], titleID: "0100F2C0115B6000"), .otherGame("01007EF00011E000"))
        XCTAssertEqual(GameBanana.fit(of: ["atmosphere/contents/0100F2C0115B6000/romfs/a"], titleID: "0100F2C0115B6000"), .works)
        XCTAssertEqual(GameBanana.fit(of: ["readme.txt"], titleID: "0100F2C0115B6000"), .noRomFS)
        XCTAssertEqual(GameBanana.fit(of: [], titleID: "0100F2C0115B6000"), .unknown)
    }

    func testParsing() {
        let mod = GameBanana.mod(["_idRow": 452172, "_sName": "Wolf Link", "_nLikeCount": 505,
                                  "_aRootCategory": ["_sName": "Playable Characters"], "_aSubmitter": ["_sName": "Author"],
                                  "_aPreviewMedia": ["_aImages": [["_sBaseUrl": "https://images.gamebanana.com/img/ss/mods", "_sFile220": "220-90_a.jpg"]]]])
        XCTAssertEqual(mod?.image?.absoluteString, "https://images.gamebanana.com/img/ss/mods/220-90_a.jpg")
        XCTAssertEqual(mod?.page.absoluteString, "https://gamebanana.com/mods/452172")
        let file = GameBanana.file(["_idRow": "1349811", "_sFile": "a.zip", "_nFilesize": "130298", "_sDownloadUrl": "https://gamebanana.com/dl/1349811",
                                    "_sAvResult": "clean", "_sAnalysisResult": "ok", "_nDownloadCount": "5"])
        XCTAssertEqual(file?.id, 1349811)
        XCTAssertEqual(file?.clean, true)
    }
}

final class SwitchScreenshotTests: XCTestCase {
    func testScreenshotsFromStorePage() {
        let base = "https://www.nintendo.com/eu/media/images/06_screenshots/games_5/nintendo_switch_6/nswitch_game/NSwitch_Game"
        let html = """
        <img src="\(base)_01_TM_Standard.jpg"><a href="\(base)_01.jpg"></a>
        <img src="\(base)_03_image950w.jpg"><a href='\(base)_02.jpg'></a><a href="\(base)_01.jpg"></a>
        <img src="/eu/media/images/06_screenshots/games_5/nintendo_switch_6/nswitch_game/NSwitch_Game_03.jpg">
        <img src="https://www.nintendo.com/eu/media/images/10_share_images/x/H2x1_Game_01.jpg">
        """
        XCTAssertEqual(SwitchMetadata.screenshots(inPage: html).map(\.lastPathComponent), ["NSwitch_Game_01.jpg", "NSwitch_Game_02.jpg", "NSwitch_Game_03.jpg"])
        XCTAssertEqual(SwitchMetadata.screenshots(inPage: html, limit: 2).count, 2)
    }

    func testStorePageFromSearch() {
        let json = #"{"response":{"docs":[{"title":"Game","url":"/it-it/Giochi/Game-1.html","dates_released_dts":["2018-05-04T00:00:00Z"]}]}}"#
        XCTAssertEqual(SwitchMetadata.parse(Data(json.utf8))?.page?.absoluteString, "https://www.nintendo.com/it-it/Giochi/Game-1.html")
    }
}

final class GameTweaksTests: XCTestCase {
    func testCatalogAndTargets() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../catalog/game-tweaks.json").standardized
        let catalog = try GameTweaksCatalog.load(from: url)
        let ocarina = try XCTUnwrap(catalog.entry(titleID: "0400486024dec000"))
        let variables = ocarina.settings.map(\.variable)
        let upscaler = try XCTUnwrap(ocarina.settings.first { $0.variable == "DM_UPSCALER" })
        XCTAssertTrue(upscaler.isOptional, "the engine keeps the game's network as the default")
        XCTAssertFalse(upscaler.fits(chip: "M1", engineDate: "2026-11-10"), "does nothing for this game before the engine named its networks")
        XCTAssertTrue(upscaler.fits(chip: "M1", engineDate: "2026-11-16"))
        XCTAssertFalse(upscaler.fits(chip: "M1"))
        XCTAssertTrue(variables.contains("DM_UPSCALER"))
        let onM1 = ocarina.settings.filter { $0.fits(chip: "M1") }.map(\.variable)
        let onM4 = ocarina.settings.filter { $0.fits(chip: "M4") }.map(\.variable)
        XCTAssertFalse(onM1.contains("DM_PRESENT_UPSCALE"))
        XCTAssertTrue(onM4.contains("DM_PRESENT_UPSCALE"))
        XCTAssertTrue(onM1.contains("DM_OPMODE") && !onM4.contains("DM_OPMODE"))
        XCTAssertEqual(GameTweaks.chipFamily("Apple M1 Pro"), "M1")
        XCTAssertEqual(GameTweaks.chipFamily("Apple M4 Max"), "M4")
        XCTAssertNil(GameTweaks.chipFamily("Intel(R) Core(TM) i9"))
        XCTAssertFalse(ocarina.settings[0].reason(language: "it").isEmpty)
        XCTAssertEqual(ocarina.settings[0].reason(language: "ja"), ocarina.settings[0].why["en"])
        for tweak in ocarina.settings { XCTAssertNotNil(tweak.source) }

        let switches = GameTweaks.envSwitches("name\tclass\tmeaning\nDM_THERMAL_CAP\tswitch\t`0` off\nDM_AB\tdiagnostic\tx\nDM_UPSCALER\tplayer\ty\n")
        XCTAssertEqual(switches["DM_THERMAL_CAP"], "switch")
        let tweak = { (name: String) in GameTweaksCatalog.Tweak(variable: name, value: "1", why: [:], source: nil) }
        XCTAssertEqual(GameTweaks.target(of: tweak("DM_DYNAMIC_RESOLUTION"), launcher: ["DM_DYNAMIC_RESOLUTION"], switches: switches), .launcher)
        XCTAssertEqual(GameTweaks.target(of: tweak("DM_THERMAL_CAP"), launcher: [], switches: switches), .env)
        XCTAssertNil(GameTweaks.target(of: tweak("DM_AB"), launcher: [], switches: switches))
        XCTAssertNil(GameTweaks.target(of: tweak("DM_TEX_RELEASE"), launcher: [], switches: switches))

        let newer = GameTweaksCatalog(version: "2026-12-01", games: [])
        XCTAssertEqual(GameTweaksCatalog.newest(catalog, newer)?.version, "2026-12-01")
        XCTAssertEqual(GameTweaksCatalog.newest(catalog, nil)?.version, catalog.version)
    }
}

final class EngineUpdateTests: XCTestCase {
    func testCompareSummary() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../catalog/native-engines.json").standardized
        let engine = try XCTUnwrap(NativeEngineCatalog.load(from: url).engine(id: "nxnative"))
        let json = """
        {"ahead_by": 3, "commits": [
          {"sha": "a", "commit": {"message": "Ocarina of Time's mist no longer flickers"}},
          {"sha": "b", "commit": {"message": "Super Mario Bros. Wonder: faster loads; Ocarina of Time too"}},
          {"sha": "c", "commit": {"message": "Unrelated fix"}}],
         "files": [{"filename": "docs/frontends.md"}, {"filename": "dm/host/x.c"}]}
        """
        let update = try XCTUnwrap(NXEngineUpdate.parse(compare: Data(json.utf8), engine: engine, latest: "ffff", latestDate: "2026-11-12",
                                                        games: ["The Legend of Zelda: Ocarina of Time", "Super Mario Bros. Wonder", "Kirby"]))
        XCTAssertEqual(update.count, 3)
        XCTAssertEqual(update.gameMentions, ["Ocarina of Time": 2, "Super Mario Bros. Wonder": 1])
        XCTAssertTrue(update.contractChanged)
        XCTAssertFalse(update.requirementsChanged)
        XCTAssertTrue(update.compareURL.absoluteString.hasSuffix("...ffff"))
        let moved = engine.at(commit: "ffff", committedAt: "2026-11-12")
        XCTAssertEqual(moved.commit, "ffff")
        XCTAssertEqual(moved.id, engine.id)
        // No channel while the fork carries nothing beyond upstream; the mechanism stays for when it does.
        XCTAssertTrue(engine.channels?.isEmpty ?? true)
        let onFork = engine.at(commit: "abcd", committedAt: nil, repo: "Gionnio/nxnative")
        XCTAssertEqual(onFork.repoURL.absoluteString, "https://github.com/Gionnio/nxnative")
        XCTAssertEqual(engine.repo, "seedds/nxnative")
    }
}


final class SwitchFileNameTests: XCTestCase {
    func testBareTitleID() {
        XCTAssertEqual(SwitchTitle.titleID(inFileName: "0400A3A01EE4C000.nup"), "0400A3A01EE4C000")
        XCTAssertEqual(SwitchTitle.titleID(inFileName: "Game [010015100B514000][v0].nsp"), "010015100B514000")
        XCTAssertEqual(SwitchTitle.titleID(inFileName: "game 0100abcdef012800 update.nsp"), "0100ABCDEF012800")
        XCTAssertNil(SwitchTitle.titleID(inFileName: "a9f3c0e1b2d4f6a8c0e2.nsp"), "a longer hex run is a hash")
        XCTAssertNil(SwitchTitle.titleID(inFileName: "ff00A3A01EE4C000.nup"), "not a Switch prefix")
        XCTAssertNil(SwitchTitle.titleID(inFileName: "Super Mario.nsp"))
        let info = SwitchFileInfo.identify(URL(fileURLWithPath: "/tmp/0400A3A01EE4C000.nup"), readPackage: false)
        XCTAssertEqual(info.titleID, "0400A3A01EE4C000")
        XCTAssertEqual(info.role, .base)
    }
}

final class ObsoleteFolderTests: XCTestCase {
    func testAllObsolete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NXPaths(root: root)
        try FileManager.default.createDirectory(at: paths.obsolete("0400486024DEC000"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.work("010015100B514000").appendingPathComponent("shader"), withIntermediateDirectories: true)
        XCTAssertEqual(paths.allObsolete().map(\.lastPathComponent), ["obsolete"])
        XCTAssertEqual(paths.allObsolete().first?.deletingLastPathComponent().lastPathComponent, "0400486024DEC000")
    }
}

final class DiskSpaceTests: XCTestCase {
    func testClonesCountOnceAndCachesKeepProfile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work/0400486024DEC000")
        for name in ["extract", "shader", "pso", "obsolete", "profile", "logs"] {
            try fm.createDirectory(at: work.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 1 << 20).write(to: work.appendingPathComponent("\(name)/data.bin"))
        }
        // The app's copy of the game data is a clone of the extraction (copyItem clones on APFS).
        let app = root.appendingPathComponent("Game.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try fm.copyItem(at: work.appendingPathComponent("extract/data.bin"), to: app.appendingPathComponent("data.bin"))

        let space = BuildFolder.measure(work, app: app)
        XCTAssertGreaterThanOrEqual(space.app.allocated, 1 << 20)
        XCTAssertEqual(space.otherCaches.allocated, 2 << 20, "extract and pso, not profile or logs")
        XCTAssertLessThan(space.otherCaches.own, space.otherCaches.allocated, "the extraction is shared with the app's clone")
        XCTAssertEqual(space.total, space.app.allocated + space.shaders.own + space.otherCaches.own + space.leftovers.own)

        XCTAssertEqual(BuildFolder.cacheItems(work).map(\.lastPathComponent), ["extract", "obsolete", "pso", "shader"])
        BuildFolder.freeCaches(work, shaders: false, others: false)
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("obsolete").path), "leftovers always go")
        XCTAssertTrue(fm.fileExists(atPath: work.appendingPathComponent("shader").path))
        BuildFolder.freeCaches(work)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: work.path).sorted(), ["logs", "profile"])
        XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent("data.bin").path))
    }

    func testShaderChainChange() {
        let engine = NativeEngine(id: "nxnative", name: "nxnative", repo: "seedds/nxnative", license: "MIT", commit: "aaaa", committedAt: nil,
                                  platforms: ["switch"], requires: .init(macOS: "26.6", xcode: "27.2", python: "3.14", brew: [], casks: [], pythonRequirements: "r.txt"),
                                  script: "s.py", profiles: "dm/games", credit: nil, channels: nil)
        func compare(_ files: [String]) -> Data {
            try! JSONSerialization.data(withJSONObject: ["ahead_by": 2, "commits": [], "files": files.map { ["filename": $0] }])
        }
        XCTAssertTrue(NXEngineUpdate.parse(compare: compare(["dm/gfx/nvn/dmsh_chain.h"]), engine: engine, latest: "b", latestDate: nil, games: [])!.shadersChanged)
        XCTAssertFalse(NXEngineUpdate.parse(compare: compare(["README.md"]), engine: engine, latest: "b", latestDate: nil, games: [])!.shadersChanged)
        XCTAssertTrue(NXEngineUpdate.parse(compare: compare((0..<300).map { "f\($0)" }), engine: engine, latest: "b", latestDate: nil, games: [])!.shadersChanged,
                      "a truncated file list may hide the chain")
    }
}

final class GamesLocationTests: XCTestCase {
    func testVerdictsAndPaths() throws {
        func volume(_ format: String, local: Bool = true, readOnly: Bool = false) -> GamesVolume {
            GamesVolume(url: URL(fileURLWithPath: "/Volumes/T7"), name: "T7", format: format, isLocal: local, isInternal: false, isReadOnly: readOnly, free: 1 << 40)
        }
        XCTAssertEqual(volume("apfs").verdict, .suitable)
        XCTAssertEqual(volume("hfs").verdict, .unsuitable(.macOSExtended))
        XCTAssertEqual(volume("exfat").verdict, .unsuitable(.fat))
        XCTAssertEqual(volume("msdos").verdict, .unsuitable(.fat))
        XCTAssertEqual(volume("smbfs", local: false).verdict, .unsuitable(.network))
        XCTAssertEqual(volume("apfs", readOnly: true).verdict, .unsuitable(.readOnly))
        XCTAssertEqual(volume("ntfs").verdict, .unsuitable(.format("ntfs")))
        let disk = URL(fileURLWithPath: "/Volumes/T7")
        XCTAssertEqual(GamesLocation.appsFolder(on: disk).path, "/Volumes/T7/Retroteca")
        XCTAssertEqual(GamesLocation.buildRoot(on: disk)?.path, "/Volumes/T7/Retroteca/.retroteca-build")
        XCTAssertNil(GamesLocation.buildRoot(on: nil))
        XCTAssertTrue(GamesLocation.isRetrotecaApp(URL(fileURLWithPath: "/Volumes/T7/Retroteca/Game.app")))
        XCTAssertTrue(GamesLocation.isRetrotecaApp(GamesLocation.macAppsFolder.appendingPathComponent("Game.app")))
        XCTAssertFalse(GamesLocation.isRetrotecaApp(URL(fileURLWithPath: "/Applications/Game.app")))
        XCTAssertFalse(GamesLocation.isRetrotecaApp(URL(fileURLWithPath: "/Volumes/T7/Other/Game.app")))
        XCTAssertEqual(GamesLocation.missingVolume(of: URL(fileURLWithPath: "/Volumes/NoSuchDisk-\(UUID().uuidString)/Retroteca/Game.app"))?.hasPrefix("NoSuchDisk"), true)
        XCTAssertNil(GamesLocation.missingVolume(of: URL(fileURLWithPath: "/Applications/Game.app")))
    }

    func testFolderSummaryMatchesACopy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("A.app/Contents")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: app.appendingPathComponent("one"))
        try Data(repeating: 2, count: 24).write(to: app.appendingPathComponent("two"))
        let copy = root.appendingPathComponent("B.app")
        try fm.copyItem(at: root.appendingPathComponent("A.app"), to: copy)
        XCTAssertEqual(FolderSummary.of(root.appendingPathComponent("A.app")), FolderSummary(files: 2, bytes: 1024))
        XCTAssertEqual(FolderSummary.of(root.appendingPathComponent("A.app")), FolderSummary.of(copy))
        try fm.removeItem(at: copy.appendingPathComponent("Contents/two"))
        XCTAssertNotEqual(FolderSummary.of(root.appendingPathComponent("A.app")), FolderSummary.of(copy))
    }
}
