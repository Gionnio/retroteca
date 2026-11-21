import SwiftUI
import AppKit
import RetrotecaCore

/// A Switch game's options, as a Platea page: settings, mods, cheats and saves of the app Retroteca built.
/// Everything is stored where the game's app reads it, so a start from Finder gets the same game.
struct SwitchOptionsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case settings, mods, cheats, saves
        var id: String { rawValue }
        var title: String {
            switch self {
            case .settings: return String(localized: "Impostazioni")
            case .mods: return String(localized: "Mod")
            case .cheats: return String(localized: "Trucchi")
            case .saves: return String(localized: "Salvataggi")
            }
        }
    }

    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let gameID: UUID
    @State private var tab: Tab = .settings
    /// Bumped after each change, so the cards read the files again.
    @State private var revision = 0
    /// Kept here, not in the tab: a change rebuilds the tab and must not close the advanced settings.
    @State private var showsAdvanced = false

    var body: some View {
        if let game = model.game(id: gameID), let titleID = game.titleID {
            let running = model.runningGameID == game.id
            ZStack(alignment: .topLeading) {
                // Settings sit over the art: blurred and darkened so the cards stay readable on bright artwork.
                GameArt(game: game, backdrop: true).blur(radius: 24, opaque: true).ignoresSafeArea()
                colors.bg.opacity(0.84).ignoresSafeArea()
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        BackButton()
                        Kicker(text: String(localized: "OPZIONI · \(model.platformName(game.platformID).uppercased())"))
                        Text(game.title).font(.system(size: 32, weight: .bold)).tracking(-0.5).foregroundStyle(colors.fg)
                            .lineLimit(2).minimumScaleFactor(0.7).padding(.top, 6).padding(.bottom, 4)
                        Text(running ? String(localized: "Il gioco è aperto: le opzioni si cambiano a gioco chiuso.")
                                     : String(localized: "Solo per questo gioco, dal prossimo avvio."))
                            .font(.system(size: 12)).foregroundStyle(running ? colors.warning : colors.secondary)
                        HStack(spacing: 8) {
                            ForEach(Tab.allCases) { item in PillButton(title: item.title, isOn: tab == item) { tab = item } }
                        }
                        .padding(.vertical, 14)
                        Group {
                            switch tab {
                            case .settings: SettingsTab(game: game, titleID: titleID, revision: $revision, showsAdvanced: $showsAdvanced)
                            case .mods: ModsTab(game: game, titleID: titleID, revision: $revision)
                            case .cheats: CheatsTab(game: game, titleID: titleID, revision: $revision)
                            case .saves: SavesTab(game: game, titleID: titleID, revision: $revision)
                            }
                        }
                        .disabled(running)
                        .id(revision)
                        if tab == .mods {
                            // Outside the rebuilt tab: the search and the opened mod survive an install.
                            OnlineModsCard(game: game, titleID: titleID, revision: $revision).padding(.top, 14)
                        }

                        Spacer(minLength: 40)
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.horizontal, 48).padding(.top, 52 + 24)
                }
                .fadesUnderTopBar()
            }
        } else {
            Color.clear.onAppear { model.back() }
        }
    }
}

// MARK: - Shared pieces

/// A translucent card with a small caps title, as COME GIRA.
struct OptionCard<Content: View>: View {
    @Environment(\.platea) private var colors
    let title: String
    var trailing: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 10.5, weight: .semibold)).tracking(1.8).foregroundStyle(colors.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(colors.secondary) }
            }
            .padding(.bottom, 4)
            content()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.line))
    }
}

/// One line of a card: label and note on the left, control on the right.
struct OptionRow<Control: View>: View {
    @Environment(\.platea) private var colors
    let title: String
    var note: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(colors.fg)
                if let note, !note.isEmpty { Text(note).font(.system(size: 11)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Rectangle().fill(colors.line).frame(height: 1).offset(y: -1) }
    }
}

/// Segmented choice in Platea's style: the chosen option in the foreground colour.
struct Segments: View {
    @Environment(\.platea) private var colors
    let options: [(value: String, label: String)]
    let selection: String
    let choose: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                Button { choose(option.value) } label: {
                    Text(option.label).font(.system(size: 12, weight: option.value == selection ? .semibold : .regular))
                        .foregroundStyle(option.value == selection ? colors.bg : colors.fg)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(option.value == selection ? colors.fg : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(colors.line))
    }
}

private func smallButton(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
    }
    .buttonStyle(PlateaButtonStyle())
    .controlSize(.small)
}

// MARK: - Settings

private struct SettingsTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game
    let titleID: String
    @Binding var revision: Int
    @Binding var showsAdvanced: Bool

    var body: some View {
        if let url = game.nativeApp, let app = NXApp(url: url) {
            let settings = app.launcherSettings
            let choices = NXSavedChoices(bundleID: app.bundleID)
            let fixed = NXGameFolder(titleID: titleID).env()
            let values = Dictionary(uniqueKeysWithValues: settings.map { ($0.env, fixed[$0.env] ?? choices.value($0.env) ?? $0.default) })
            let sections = orderedSections(settings)
            VStack(alignment: .leading, spacing: 14) {
                if let entry = model.switchGames.tweaks?.entry(titleID: titleID) {
                    RecommendedCard(entry: entry, settings: settings, values: values, choices: choices, titleID: titleID, revision: $revision,
                                    title: { settingTitle($0) })
                }
                HStack(alignment: .top, spacing: 16) {
                    ForEach(sections.filter { $0 != "Performance" }, id: \.self) { section in
                        OptionCard(title: sectionTitle(section).uppercased()) {
                            ForEach(settings.filter { $0.section == section && $0.isShown(values: values) }) { setting in
                                settingRow(setting, values: values, fixed: fixed, choices: choices)
                            }
                        }
                    }
                }
                if sections.contains("Performance") {
                    OptionCard(title: String(localized: "PRESTAZIONI")) {
                        Button { withAnimation(.easeOut(duration: 0.15)) { showsAdvanced.toggle() } } label: {
                            Label(showsAdvanced ? String(localized: "Nascondi le avanzate") : String(localized: "Mostra le avanzate"),
                                  systemImage: showsAdvanced ? "chevron.down" : "chevron.right").font(.system(size: 12))
                        }
                        .buttonStyle(.plain).foregroundStyle(colors.secondary)
                        if showsAdvanced {
                            ForEach(settings.filter { $0.section == "Performance" && $0.isShown(values: values) }) { setting in
                                settingRow(setting, values: values, fixed: fixed, choices: choices)
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    smallButton(String(localized: "Ripristina i valori provati")) { choices.reset(settings); revision += 1 }
                }
            }
        } else {
            OptionCard(title: String(localized: "IMPOSTAZIONI")) {
                Text("Le impostazioni arrivano con l'app del gioco: costruiscila prima.").font(.system(size: 12.5)).foregroundStyle(colors.secondary)
            }
        }
    }

    @ViewBuilder private func settingRow(_ setting: NXSetting, values: [String: String], fixed: [String: String], choices: NXSavedChoices) -> some View {
        let value = values[setting.env] ?? setting.default
        let isFixed = fixed[setting.env] != nil
        OptionRow(title: settingTitle(setting), note: isFixed ? String(localized: "Fissato nel file env.txt del gioco") : nil) {
            HStack(spacing: 8) {
                if isFixed {
                    smallButton(String(localized: "Sblocca")) {
                        try? NXGameFolder(titleID: titleID).setEnv(setting.env, nil)
                        revision += 1
                    }
                }
                control(setting, value: value) { choices.set(setting, to: $0); revision += 1 }
                    .disabled(isFixed)
            }
        }
    }

    @ViewBuilder private func control(_ setting: NXSetting, value: String, set: @escaping (String) -> Void) -> some View {
        switch setting.kind {
        case .toggle:
            Toggle("", isOn: Binding(get: { value == setting.onValue }, set: { set($0 ? setting.onValue : setting.offValue) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
        case .range:
            let number = Double(value) ?? Double(setting.default) ?? 0
            HStack(spacing: 8) {
                // Continuous slider (a stepped one draws a tick for every step), snapped to the step when saved.
                Slider(value: Binding(get: { number }, set: { value in
                    let step = setting.step ?? 0.05
                    set(Self.format((value / step).rounded() * step, step: setting.step))
                }), in: (setting.min ?? 0)...(setting.max ?? 1))
                    .frame(width: 150)
                Text(Self.percent(number, setting: setting)).font(.system(size: 11, design: .monospaced)).foregroundStyle(colors.secondary).frame(width: 42, alignment: .trailing)
            }
        case .choice:
            let options = (setting.options ?? []).map { (value: $0.first ?? "", label: optionLabel(setting, $0)) }
            if options.count <= 3 {
                Segments(options: options, selection: value, choose: set)
            } else {
                Picker("", selection: Binding(get: { value }, set: set)) {
                    ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden().frame(width: 190)
            }
        }
    }

    static func format(_ number: Double, step: Double?) -> String {
        let decimals = (step ?? 0.05) < 0.1 ? 2 : 1
        return String(format: "%.\(decimals)f", number)
    }

    static func percent(_ number: Double, setting: NXSetting) -> String {
        (setting.max ?? 1) <= 1 ? "\(Int((number * 100).rounded()))%" : format(number, step: setting.step)
    }

    private func orderedSections(_ settings: [NXSetting]) -> [String] {
        var seen: [String] = []
        for setting in settings where !seen.contains(setting.section) { seen.append(setting.section) }
        return seen
    }

    private func sectionTitle(_ section: String) -> String {
        switch section {
        case "Game": return String(localized: "Gioco")
        case "Controls": return String(localized: "Comandi")
        case "Performance": return String(localized: "Prestazioni")
        default: return section
        }
    }

    /// The engine's labels are English: the common ones in the user's language, the rest as they come.
    private func settingTitle(_ setting: NXSetting) -> String {
        switch setting.env {
        case "DM_FPS_TARGET": return String(localized: "Frequenza")
        case "DM_DYNAMIC_RESOLUTION": return String(localized: "Risoluzione dinamica")
        case "DM_UPSCALER": return String(localized: "Upscaler del gioco")
        case "DM_SW2": return String(localized: "Controller Switch 2")
        case "DM_RENDER_SCALE": return String(localized: "Scala di rendering")
        case "DM_OPMODE": return String(localized: "Modalità console")
        case "DM_PRESENT_UPSCALE": return String(localized: "Upscaling")
        case "DM_LANG": return String(localized: "Lingua del gioco")
        case "DM_FULLSCREEN": return String(localized: "Schermo")
        case "DM_RUMBLE": return String(localized: "Vibrazione")
        case "DM_RUMBLE_GAIN": return String(localized: "Intensità della vibrazione")
        case "DM_RUMBLE_MIN": return String(localized: "Soglia della vibrazione")
        case "DM_PAD_PRESS_TO_JOIN": return String(localized: "Premi un tasto per entrare")
        case "DM_PRESENT_SNAP": return String(localized: "Buffer dei fotogrammi")
        case "DM_PSO_MTL4": return String(localized: "Pipeline Metal 4")
        case "DM_PSO_PREBUILD": return String(localized: "Pipeline preparate in anticipo")
        case "DM_NVN_ENC_THREAD": return String(localized: "Thread di codifica")
        case "DM_METAL_HUD": return String(localized: "HUD delle prestazioni")
        case "DM_FPS_HOLD": return String(localized: "Trattieni i fotogrammi in ritardo")
        default: return setting.label
        }
    }

    private func optionLabel(_ setting: NXSetting, _ option: [String]) -> String {
        let value = option.first ?? "", label = option.count > 1 ? option[1] : value
        if setting.env == "DM_LANG" {
            return Locale.current.localizedString(forIdentifier: value)?.capitalized(with: Locale.current) ?? label
        }
        switch label {
        case "Docked": return String(localized: "Dock")
        case "Handheld": return String(localized: "Portatile")
        case "Window": return String(localized: "Finestra")
        case "Fullscreen": return String(localized: "Schermo intero")
        case "Standard": return String(localized: "Standard")
        default: return label
        }
    }
}

// MARK: - Mods

private struct ModsTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game
    let titleID: String
    @Binding var revision: Int
    @State private var error: String?

    private var store: NXMods {
        NXMods(folder: NXGameFolder(titleID: titleID), record: NXPaths.standard.root.appendingPathComponent("mods/\(titleID).json"))
    }

    var body: some View {
        let mods = store.list()
        let conflicts = store.conflicts(mods)
        OptionCard(title: String(localized: "MOD DEI FILE DEL GIOCO"),
                   trailing: mods.isEmpty ? nil : String(localized: "\(mods.count) installate · \(mods.filter(\.isOn).count) attive")) {
            if mods.isEmpty {
                Text("Nessuna mod. Aggiungi uno zip o una cartella con romfs.")
                    .font(.system(size: 12.5)).foregroundStyle(colors.secondary).padding(.vertical, 4)
            }
            ForEach(Array(mods.enumerated()), id: \.element.id) { index, mod in
                OptionRow(title: mod.folder, note: note(mod)) {
                    HStack(spacing: 6) {
                        Button { move(mods, from: index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.plain).foregroundStyle(colors.secondary).disabled(index == 0)
                        Button { move(mods, from: index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.plain).foregroundStyle(colors.secondary).disabled(index == mods.count - 1)
                        Text("\(index + 1)°").font(.system(size: 11)).foregroundStyle(colors.secondary).frame(width: 24)
                        Toggle("", isOn: Binding(get: { mod.isOn }, set: { on in
                            var updated = mods
                            updated[index].isOn = on
                            save(updated)
                        })).toggleStyle(.switch).labelsHidden().controlSize(.small)
                        Button { remove(mod) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(colors.secondary)
                    }
                }
            }
            ForEach(Array(conflicts.enumerated()), id: \.offset) { _, conflict in
                Label(String(localized: "\(conflict.upper) e \(conflict.lower) cambiano \(conflict.files) file uguali: vince quella più in alto."),
                      systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(colors.warning).padding(.top, 4)
            }
            if let error { Label(error, systemImage: "xmark.octagon").font(.system(size: 12)).foregroundStyle(.red).padding(.top, 4) }
            HStack(spacing: 8) {
                smallButton(String(localized: "Aggiungi mod…"), systemImage: "plus") { add() }
                smallButton(String(localized: "Apri la cartella")) {
                    try? FileManager.default.createDirectory(at: store.folder.mods, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(store.folder.mods)
                }
            }
            .padding(.top, 10)
            Text("Solo mod dei file del gioco (romfs); quella più in alto vince.")
                .font(.system(size: 11)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }
    }

    private func note(_ mod: NXMods.Mod) -> String {
        var parts: [String] = []
        if let source = mod.source { parts.append(source) }
        parts.append(String(localized: "aggiunta \(mod.addedAt.formatted(.relative(presentation: .named)))"))
        if !mod.isOn { parts.append(String(localized: "spenta")) }
        return parts.joined(separator: " · ")
    }

    private func move(_ mods: [NXMods.Mod], from index: Int, by offset: Int) {
        var updated = mods
        let target = index + offset
        guard updated.indices.contains(target) else { return }
        updated.swapAt(index, target)
        save(updated)
    }

    private func save(_ mods: [NXMods.Mod]) {
        do { try store.save(mods); error = nil } catch { self.error = error.localizedDescription }
        revision += 1
    }

    private func remove(_ mod: NXMods.Mod) {
        do { try store.remove(mod); error = nil } catch { self.error = error.localizedDescription }
        revision += 1
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Aggiungi")
        panel.message = String(localized: "Scegli lo zip o la cartella della mod.")
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                var failures: [String] = []
                for url in panel.urls {
                    do { _ = try store.add(url, titleID: titleID) } catch { failures.append("\(url.lastPathComponent): \(Self.explain(error))") }
                }
                error = failures.isEmpty ? nil : failures.joined(separator: "\n")
                if failures.isEmpty { model.message = String(localized: "Mod aggiunte.") }
                revision += 1
            }
        }
    }

    static func explain(_ error: Error) -> String {
        switch error as? NXMods.Failure {
        case .noRomFS: return String(localized: "nessuna cartella romfs: funzionano solo le mod dei file del gioco")
        case .codeMod: return String(localized: "cambia il codice del gioco: non funziona con un'app costruita")
        case .otherGame(let id): return String(localized: "è per un altro gioco (\(id))")
        case .severalRoots: return String(localized: "contiene più varianti: estrai quella che vuoi")
        case .tooLong: return String(localized: "troppe mod attive insieme")
        case nil: return error.localizedDescription
        }
    }
}

// MARK: - Cheats

private struct CheatsTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game
    let titleID: String
    @Binding var revision: Int
    @State private var error: String?

    var body: some View {
        if let url = game.nativeApp, let app = NXApp(url: url), let buildID = app.cheatBuildID {
            let cheats = NXCheats(folder: NXGameFolder(titleID: titleID), buildID: buildID)
            let list = cheats.list()
            OptionCard(title: String(localized: "TRUCCHI"), trailing: String(localized: "versione \(app.version ?? "?") · build \(buildID)")) {
                if list.isEmpty {
                    Text("Nessun trucco per questa versione (\(buildID).txt, formato Atmosphère).")
                        .font(.system(size: 12.5)).foregroundStyle(colors.secondary).padding(.vertical, 4)
                } else {
                    OptionRow(title: String(localized: "Trucchi attivi"), note: String(localized: "Interruttore generale: spento, nessun trucco gira")) {
                        Toggle("", isOn: Binding(get: { cheats.masterOn }, set: { cheats.masterOn = $0; revision += 1 }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    ForEach(list.filter { !$0.isMaster }) { cheat in
                        OptionRow(title: cheat.name) {
                            Toggle("", isOn: Binding(get: { cheat.isOn }, set: { on in
                                var updated = list
                                if let i = updated.firstIndex(where: { $0.name == cheat.name }) { updated[i].isOn = on }
                                try? cheats.save(updated)
                                revision += 1
                            })).toggleStyle(.switch).labelsHidden().controlSize(.small)
                        }
                    }
                }
                if let error { Label(error, systemImage: "xmark.octagon").font(.system(size: 12)).foregroundStyle(.red).padding(.top, 4) }
                HStack(spacing: 8) {
                    smallButton(String(localized: "Importa file di trucchi…"), systemImage: "plus") { importFile(cheats) }
                    smallButton(String(localized: "Apri la cartella")) {
                        try? FileManager.default.createDirectory(at: cheats.folder.cheats, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(cheats.folder.cheats)
                    }
                }
                .padding(.top, 10)
                Text("I trucchi nuovi partono spenti. Nel gioco: ⌘⇧C.")
                    .font(.system(size: 11)).foregroundStyle(colors.secondary).padding(.top, 8)
            }
        } else {
            OptionCard(title: String(localized: "TRUCCHI")) {
                Text("Costruisci prima l'app del gioco.").font(.system(size: 12.5)).foregroundStyle(colors.secondary)
            }
        }
    }

    private func importFile(_ cheats: NXCheats) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Importa")
        panel.message = String(localized: "Scegli il file di trucchi (.txt, formato Atmosphère).")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try cheats.importFile(url)
                    error = nil
                    model.message = String(localized: "Trucchi importati: partono spenti.")
                } catch NXCheats.Failure.otherBuild(let id) {
                    error = String(localized: "Questi trucchi sono per la build \(id), non per questa.")
                } catch {
                    self.error = String(localized: "Nel file non ci sono trucchi.")
                }
                revision += 1
            }
        }
    }
}

// MARK: - Saves

private struct SavesTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game
    let titleID: String
    @Binding var revision: Int
    @State private var restoreTarget: URL?
    @State private var error: String?

    private var saves: NXSaves {
        NXSaves(folder: NXGameFolder(titleID: titleID), backups: NXPaths.standard.root.appendingPathComponent("SaveBackups/\(titleID)", isDirectory: true))
    }

    var body: some View {
        let saves = saves
        let backups = saves.list()
        HStack(alignment: .top, spacing: 16) {
            OptionCard(title: String(localized: "SALVATAGGIO")) {
                OptionRow(title: String(localized: "Ultimo salvataggio"), note: nil) {
                    Text(saves.lastModified.map { "\($0.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: saves.size, countStyle: .file))" } ?? String(localized: "nessuno"))
                        .font(.system(size: 12)).foregroundStyle(colors.fg)
                }
                OptionRow(title: String(localized: "Copie di sicurezza"), note: nil) {
                    Text("\(backups.count)").font(.system(size: 12)).foregroundStyle(colors.fg)
                }
                if let error { Label(error, systemImage: "xmark.octagon").font(.system(size: 12)).foregroundStyle(.red).padding(.top, 4) }
                HStack(spacing: 8) {
                    smallButton(String(localized: "Copia di sicurezza ora")) {
                        do { try saves.backUp(); model.message = String(localized: "Copia di sicurezza fatta."); error = nil } catch { self.error = error.localizedDescription }
                        revision += 1
                    }
                    .disabled(!saves.hasSave)
                    smallButton(String(localized: "Importa salvataggio…")) { importSave(saves) }
                    smallButton(String(localized: "Apri la cartella")) { NSWorkspace.shared.open(saves.folder.root) }
                }
                .padding(.top, 10)
                Text("Da Ryujinx: la cartella numerata in bis/user/save.")
                    .font(.system(size: 11)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            OptionCard(title: String(localized: "COPIE DATATE")) {
                if backups.isEmpty {
                    Text("Nessuna copia ancora.").font(.system(size: 12.5)).foregroundStyle(colors.secondary)
                }
                ForEach(backups.prefix(8), id: \.self) { backup in
                    OptionRow(title: backup.lastPathComponent, note: nil) {
                        smallButton(String(localized: "Ripristina")) { restoreTarget = backup }
                    }
                }
                Text("ICLOUD").font(.system(size: 10.5, weight: .semibold)).tracking(1.8).foregroundStyle(colors.secondary).padding(.top, 12)
                if let url = game.nativeApp, let app = NXApp(url: url) {
                    let choices = NXSavedChoices(bundleID: app.bundleID)
                    OptionRow(title: String(localized: "Condividi con l'iPhone"), note: choices.cloudFolder.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? String(localized: "iCloud Drive › nxnative Saves")) {
                        Toggle("", isOn: Binding(get: { choices.cloudFolder != nil }, set: { on in
                            if on {
                                let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/nxnative Saves", isDirectory: true)
                                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                choices.cloudFolder = folder.path
                            } else {
                                choices.cloudFolder = nil
                            }
                            revision += 1
                        })).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                }
            }
        }
        .confirmationDialog(String(localized: "Ripristinare questa copia?"), isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } })) {
            Button("Ripristina", role: .destructive) {
                if let target = restoreTarget {
                    do { try saves.restore(target); model.message = String(localized: "Salvataggio ripristinato."); error = nil } catch { self.error = error.localizedDescription }
                }
                restoreTarget = nil
                revision += 1
            }
        } message: {
            Text("Il salvataggio attuale viene copiato prima di essere sostituito.")
        }
    }

    private func importSave(_ saves: NXSaves) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Importa")
        panel.message = String(localized: "Scegli la cartella del salvataggio da importare.")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try saves.importFolder(url); model.message = String(localized: "Salvataggio importato."); error = nil } catch { self.error = String(localized: "La cartella non contiene un salvataggio.") }
                revision += 1
            }
        }
    }
}

/// Values Retroteca recommends for this game, each with why and where the engine's notes say so.
/// Only settings the built engine has are shown; the optional ones are applied one by one.
private struct RecommendedCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let entry: GameTweaksCatalog.GameEntry
    let settings: [NXSetting]
    let values: [String: String]
    let choices: NXSavedChoices
    let titleID: String
    @Binding var revision: Int
    let title: (NXSetting) -> String

    private var language: String? { Locale.current.language.languageCode?.identifier }

    var body: some View {
        let launcher = Set(settings.map(\.env))
        let env = NXGameFolder(titleID: titleID).env()
        let chip = GameTweaks.currentChipFamily
        let engineDate = model.switchGames.engine?.committedAt
        let rows = entry.settings.filter { $0.fits(chip: chip, engineDate: engineDate) }.compactMap { tweak -> (GameTweaksCatalog.Tweak, TweakTarget)? in
            GameTweaks.target(of: tweak, launcher: launcher, switches: model.switchGames.envSwitches).map { (tweak, $0) }
        }
        if !rows.isEmpty {
            let pending = rows.filter { !$0.0.isOptional && current($0.0, target: $0.1, env: env) != $0.0.value }
            OptionCard(title: chip.map { String(localized: "CONSIGLIATE PER QUESTO GIOCO SU \($0)") } ?? String(localized: "CONSIGLIATE PER QUESTO GIOCO"),
                       trailing: pending.isEmpty ? String(localized: "tutte applicate") : String(localized: "\(pending.count) da applicare")) {
                ForEach(rows, id: \.0.id) { tweak, target in
                    let applied = current(tweak, target: target, env: env) == tweak.value
                    OptionRow(title: name(tweak), note: tweak.reason(language: language)) {
                        HStack(spacing: 8) {
                            if let source = tweak.source {
                                Button { NSWorkspace.shared.open(source) } label: { Image(systemName: "doc.text") }
                                    .buttonStyle(.plain).foregroundStyle(colors.secondary).help(String(localized: "Da dove viene questo consiglio"))
                            }
                            if applied {
                                PlateaChip(text: "✓ " + valueLabel(tweak), tint: colors.ok)
                            } else {
                                if tweak.isOptional { PlateaChip(text: String(localized: "facoltativa")) }
                                smallButton(String(localized: "Usa \(valueLabel(tweak))")) { apply(tweak, target: target) }
                            }
                        }
                    }
                }
                if !pending.isEmpty {
                    smallButton(String(localized: "Applica le consigliate"), systemImage: "checkmark.circle") {
                        for (tweak, target) in pending { apply(tweak, target: target) }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func setting(_ tweak: GameTweaksCatalog.Tweak) -> NXSetting? { settings.first { $0.env == tweak.variable } }

    private func current(_ tweak: GameTweaksCatalog.Tweak, target: TweakTarget, env: [String: String]) -> String? {
        switch target {
        case .launcher: return values[tweak.variable]
        case .env: return env[tweak.variable]
        }
    }

    private func name(_ tweak: GameTweaksCatalog.Tweak) -> String {
        setting(tweak).map(title) ?? tweak.variable
    }

    private func valueLabel(_ tweak: GameTweaksCatalog.Tweak) -> String {
        guard let setting = setting(tweak) else { return tweak.value }
        if setting.kind == .toggle { return tweak.value == setting.onValue ? String(localized: "acceso") : String(localized: "spento") }
        return setting.options?.first { $0.first == tweak.value }.flatMap { $0.count > 1 ? $0[1] : nil } ?? tweak.value
    }

    private func apply(_ tweak: GameTweaksCatalog.Tweak, target: TweakTarget) {
        switch target {
        case .launcher: if let setting = setting(tweak) { choices.set(setting, to: tweak.value) }
        case .env: try? NXGameFolder(titleID: titleID).setEnv(tweak.variable, tweak.value)
        }
        ActivityLog.write("Recommended setting applied for \(entry.title): \(tweak.variable)=\(tweak.value)")
        revision += 1
    }
}

