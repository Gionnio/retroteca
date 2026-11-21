import SwiftUI
import RetrotecaCore
import UniformTypeIdentifiers

/// "COME SI COSTRUISCE" on a Switch game's page: the user's files, the engine's profile, tools, keys, space, then Build.
struct SwitchBuildCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game

    var body: some View {
        let manager = model.switchGames
        let toolchain = manager.toolchain
        let profile = manager.profile(for: game)
        VStack(alignment: .leading, spacing: 10) {
            Text("COME SI COSTRUISCE").font(.system(size: 10.5, weight: .semibold)).tracking(1.8).foregroundStyle(colors.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow(alignment: .top) {
                    key("Il tuo gioco")
                    VStack(alignment: .leading, spacing: 2) {
                        if !game.files.isEmpty, !model.switchHasBase(game) {
                            Text("Manca il gioco base: aggiungi il suo file NSP o XCI.")
                                .font(.system(size: 12)).foregroundStyle(colors.warning).fixedSize(horizontal: false, vertical: true)
                        }
                        if game.files.isEmpty {
                            Text(game.foundOnMac == true ? String(localized: "App trovata sul Mac: per ricostruirla aggiungi il gioco.")
                                                         : String(localized: "Nessun file"))
                                .font(.system(size: 12)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(game.files, id: \.self) { file in
                            Text(fileLine(file)).font(.system(size: 12)).foregroundStyle(colors.fg).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                GridRow(alignment: .top) {
                    key("Profilo")
                    if let profile {
                        value(String(localized: "\(manager.engine?.name ?? "") conosce \(profile.name)") + (profile.builds.map { String(localized: " · provato su \($0)") } ?? ""), color: colors.ok)
                    } else if manager.profiles.isEmpty {
                        value(String(localized: "Si vede quando gli strumenti sono pronti"))
                    } else {
                        value(String(localized: "Nessun profilo: costruzione provvisoria, può non partire."), color: colors.warning)
                    }
                }
                if game.titleID != nil, !model.switchVersions(of: game).isEmpty {
                    GridRow {
                        key("Versione")
                        versionPicker
                    }
                }
                if let engine = manager.engine {
                    GridRow {
                        key("Motore")
                        value("\(engine.name) \(engine.shortCommit) · \(engine.license) · github.com/\(engine.repo)")
                    }
                }
                GridRow {
                    key("Spazio")
                    let needed = manager.spaceNeeded(for: game), free = manager.freeSpace
                    value(String(localized: "Servono circa \(bytes(needed)), liberi \(bytes(free))"), color: free < needed ? .red : colors.fg)
                }
                GridRow(alignment: .top) {
                    key("Tempo")
                    value(String(localized: "Da mezz'ora a qualche ora."))
                }
                GridRow {
                    key("App")
                    value((game.nativeApp ?? manager.appURL(for: profile?.name ?? game.title)).path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                }
            }
            if model.switchNeedsRebuild(game) {
                HStack(spacing: 10) {
                    Label("C'è un aggiornamento del gioco: ricostruisci l'app.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12.5)).foregroundStyle(colors.warning).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Ricostruisci") { model.buildSwitchGame(game) }.buttonStyle(PlateaButtonStyle()).disabled(game.status == .missingFiles)
                        .disabled(!(toolchain?.isReady ?? false) || manager.isBusy || !model.switchHasBase(game))
                }
            }
            Divider().overlay(colors.line)
            toolsStep(toolchain)
            keysStep(toolchain)
            step(game.nativeApp != nil, String(localized: "Costruzione dell'app Mac dal tuo gioco, su questo Mac"))
            step(game.nativeApp != nil, String(localized: "Il gioco si apre da Retroteca come app nativa"))
            if let error = manager.buildErrors[game.id] ?? manager.setupError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 12))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if manager.builds[game.id] != nil {
                    Button("Schermata di costruzione") { model.open(.build(game.id)) }.buttonStyle(PlateaButtonStyle())
                }
                if game.nativeApp != nil {
                    Button("Ricostruisci") { model.buildSwitchGame(game) }.buttonStyle(PlateaButtonStyle()).disabled(game.status == .missingFiles)
                        .disabled(!(toolchain?.isReady ?? false) || manager.isBusy || !model.switchHasBase(game))
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.line))
        .onAppear { if manager.toolchain == nil { manager.refresh() } }
    }

    /// The versions the user has; the engine's tested ones are marked, the recommended one is the default.
    private var versionPicker: some View {
        let available = model.switchVersions(of: game)
        let tested = game.titleID.map { model.switchGames.versions(for: $0) } ?? NXProfileVersions()
        let chosen = model.switchBuildVersion(of: game)
        func label(_ version: Int) -> String {
            let name = tested.tested[version].map { "\($0) (v\(version))" } ?? (version == 0 ? String(localized: "gioco base (v0)") : "v\(version)")
            var parts = [name]
            if tested.tested[version] != nil { parts.append(String(localized: "provata dal motore")) }
            if version == tested.choose(from: available) { parts.append(String(localized: "consigliata")) }
            return parts.joined(separator: " · ")
        }
        return HStack(spacing: 8) {
            if available.count > 1 {
                Picker("", selection: Binding(get: { chosen ?? available.last ?? 0 }, set: { model.setSwitchBuildVersion($0, for: game.id) })) {
                    ForEach(available, id: \.self) { Text(label($0)).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 360)
            } else if let only = available.first {
                value(label(only))
            }
            if let chosen, tested.tested[chosen] == nil, !tested.tested.isEmpty {
                Text("non provata: può girare peggio").font(.system(size: 11)).foregroundStyle(colors.warning)
            }
        }
    }

    // MARK: Steps

    @ViewBuilder private func toolsStep(_ toolchain: NXToolchain?) -> some View {
        let manager = model.switchGames
        let missing = toolchain.map { Set($0.missing.keys).subtracting([.keys]) } ?? []
        VStack(alignment: .leading, spacing: 6) {
            step(toolchain != nil && missing.isEmpty, toolchain == nil ? String(localized: "Controllo degli strumenti…")
                 : missing.isEmpty ? String(localized: "Strumenti pronti: \(toolchain?.xcodeVersion ?? "Xcode"), Metal, Python, \(manager.engine?.name ?? "")")
                 : String(localized: "Strumenti da preparare: \(missing.compactMap { item in toolchain.map { label(item, $0) } }.sorted().joined(separator: ", "))"))
            if let toolchain, !missing.isEmpty {
                if missing.contains(.xcode) || missing.contains(.metal) || missing.contains(.macOS) {
                    Text("Serve \(toolchain.missing[.macOS] ?? toolchain.missing[.xcode] ?? "Metal Toolchain"): installalo da developer.apple.com, poi esegui \"xcodebuild -downloadComponent MetalToolchain\".")
                        .font(.system(size: 11.5)).foregroundStyle(colors.secondary).padding(.leading, 22).fixedSize(horizontal: false, vertical: true)
                }
                if !toolchain.installable.isEmpty {
                    HStack(spacing: 8) {
                        Button {
                            Task { await manager.prepareTools() }
                        } label: {
                            Label(manager.setupText ?? String(localized: "Prepara gli strumenti"), systemImage: manager.setupText == nil ? "wrench.and.screwdriver" : "hourglass")
                        }
                        .buttonStyle(PlateaButtonStyle()).disabled(manager.isBusy)
                        if manager.setupText != nil { ProgressView().controlSize(.small) }
                    }
                    .padding(.leading, 22)
                }
            }
        }
    }

    @ViewBuilder private func keysStep(_ toolchain: NXToolchain?) -> some View {
        let manager = model.switchGames
        let needsKeys = !game.files.allSatisfy { $0.pathExtension.lowercased() == "nup" }
        if needsKeys {
            let has = toolchain.map { $0.missing[.keys] == nil } ?? false
            VStack(alignment: .leading, spacing: 6) {
                step(has, has ? String(localized: "Chiavi della tua console importate")
                              : String(localized: "Servono le chiavi della tua console (prod.keys), esportate dalla tua Switch"))
                if !has {
                    HStack(spacing: 8) {
                        Button("Importa prod.keys…") { chooseKeys() }.buttonStyle(PlateaButtonStyle())
                        ForEach(manager.existingKeys, id: \.self) { url in
                            Button(String(localized: "Usa quelle di \(appName(of: url))")) { importKeys(url) }.buttonStyle(PlateaButtonStyle())
                        }
                    }
                    .padding(.leading, 22)
                }
            }
        }
    }

    /// What is missing, in the user's language.
    private func label(_ item: NXToolchain.Item, _ toolchain: NXToolchain) -> String {
        switch item {
        case .venv: return String(localized: "ambiente Python")
        case .homebrew: return "Homebrew"
        case .keys: return "prod.keys"
        default: return toolchain.missing[item] ?? item.rawValue
        }
    }

    private func chooseKeys() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Importa")
        panel.message = String(localized: "Scegli il file prod.keys esportato dalla tua console.")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in importKeys(url) }
        }
    }

    private func importKeys(_ url: URL) {
        do {
            try model.switchGames.importKeys(from: url)
            model.message = String(localized: "Chiavi importate.")
        } catch is NXKeys.Failure {
            model.message = String(localized: "Non è un file prod.keys valido.")
        } catch {
            model.message = error.localizedDescription
        }
    }

    private func appName(of url: URL) -> String {
        let folder = url.pathComponents.dropLast().first { ["NXLibrary", "Ryujinx", "eden", "citron"].contains($0) } ?? ""
        return folder == "NXLibrary" ? "NX Library" : folder.capitalized
    }

    private func fileLine(_ url: URL) -> String {
        let name = url.lastPathComponent
        let role: String
        switch SwitchTitle.titleID(inFileName: name).flatMap(SwitchTitle.role(of:)) {
        case .update: role = String(localized: "Aggiornamento") + (SwitchTitle.version(inFileName: name).map { " v\($0)" } ?? "")
        case .dlc: role = "DLC"
        default: role = url.pathExtension.lowercased() == "nup" ? "NUP" : String(localized: "Gioco base")
        }
        return "\(role) · \(name)"
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    private func key(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(colors.secondary)
    }

    private func value(_ text: String, color: Color? = nil) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color ?? colors.fg).fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ done: Bool, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark" : "circle").font(.system(size: 10, weight: .bold))
                .foregroundStyle(done ? colors.ok : colors.secondary).frame(width: 14)
            Text(text).font(.system(size: 12.5)).foregroundStyle(done ? colors.fg : colors.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

