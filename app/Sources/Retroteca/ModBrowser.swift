import SwiftUI
import RetrotecaCore

/// Mods from GameBanana for a Switch game, in the Mod tab: the most downloaded first, each checked before it is offered
/// (only game-file mods for this game work with a native build). Installing goes through the same folder as a dropped mod.
struct OnlineModsCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game
    let titleID: String
    @Binding var revision: Int

    @State private var gbGame: (id: Int, name: String)?
    @State private var mods: [GameBanana.Mod] = []
    @State private var page = 1
    @State private var search = ""
    @State private var loading = false
    @State private var failure: String?
    @State private var opened: GameBanana.Mod?
    @State private var files: [GameBanana.File] = []
    @State private var fits: [Int: GameBanana.Fit] = [:]
    @State private var installing: Int?
    @State private var started = false

    private let client = GameBanana()

    var body: some View {
        OptionCard(title: String(localized: "MOD ONLINE"), trailing: gbGame.map { "GameBanana · \($0.name)" }) {
            if !started {
                HStack(spacing: 10) {
                    Text("Mod da GameBanana per questo gioco.")
                        .font(.system(size: 12.5)).foregroundStyle(colors.secondary)
                    Spacer()
                    Button { started = true; Task { await load(reset: true) } } label: { Label("Sfoglia", systemImage: "globe") }
                        .buttonStyle(PlateaButtonStyle())
                }
            } else {
                HStack(spacing: 8) {
                    TextField(String(localized: "Cerca tra le mod"), text: $search)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                        .onSubmit { Task { await load(reset: true) } }
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                    if let gbGame {
                        Button(String(localized: "Pagina su GameBanana")) { NSWorkspace.shared.open(URL(string: "https://gamebanana.com/games/\(gbGame.id)")!) }
                            .buttonStyle(.link).font(.system(size: 12))
                    }
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(colors.warning).padding(.top, 6)
                }
                if let opened {
                    modDetail(opened).padding(.top, 10)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(mods) { mod in tile(mod) }
                }
                .padding(.top, 10)
                if !mods.isEmpty && mods.count % 30 == 0 {
                    Button(String(localized: "Altre mod")) { Task { await load(reset: false) } }
                        .buttonStyle(PlateaButtonStyle()).padding(.top, 8).disabled(loading)
                }
            }
        }
    }

    // MARK: Pieces

    private func tile(_ mod: GameBanana.Mod) -> some View {
        Button { Task { await open(mod) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: mod.image) { image in image.resizable().scaledToFill() } placeholder: { colors.card }
                    .frame(height: 104).frame(maxWidth: .infinity).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(opened?.id == mod.id ? colors.accent : .clear, lineWidth: 2.5).padding(-3))
                Text(mod.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(colors.fg).lineLimit(1)
                Text([mod.category, "♥ \(mod.likes)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(colors.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modDetail(_ mod: GameBanana.Mod) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(mod.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(colors.fg)
                if let author = mod.author { Text(String(localized: "di \(author)")).font(.system(size: 12)).foregroundStyle(colors.secondary) }
                Spacer()
                Button(String(localized: "Apri la pagina")) { NSWorkspace.shared.open(mod.page) }.buttonStyle(.link).font(.system(size: 12))
                Button { opened = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(colors.secondary)
            }
            if files.isEmpty { ProgressView().controlSize(.small) }
            ForEach(files) { file in
                OptionRow(title: file.name, note: [file.note, ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)].compactMap { $0 }.joined(separator: " · ")) {
                    HStack(spacing: 8) {
                        fitChip(fits[file.id], clean: file.clean)
                        if fits[file.id] == .works, file.clean {
                            Button { Task { await install(file, of: mod) } } label: {
                                Label(installing == file.id ? String(localized: "Installo…") : String(localized: "Installa"), systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(PlateaButtonStyle()).disabled(installing != nil || model.runningGameID == game.id)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(colors.card, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func fitChip(_ fit: GameBanana.Fit?, clean: Bool) -> some View {
        if !clean {
            PlateaChip(text: String(localized: "Non verificato da GameBanana"), tint: .red)
        } else {
            switch fit {
            case .works?: PlateaChip(text: String(localized: "Funziona"), tint: colors.ok)
            case .codeMod?: PlateaChip(text: String(localized: "Cambia il codice: non funziona"), tint: colors.warning)
            case .otherGame?: PlateaChip(text: String(localized: "Per un altro gioco"), tint: colors.warning)
            case .noRomFS?: PlateaChip(text: String(localized: "Senza romfs: non funziona"), tint: colors.warning)
            case .unknown?: PlateaChip(text: String(localized: "Contenuto sconosciuto"), tint: colors.secondary)
            case nil: ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: Loading

    private func load(reset: Bool) async {
        loading = true
        defer { loading = false }
        do {
            if gbGame == nil {
                gbGame = try await client.findGame(game.title)
                guard gbGame != nil else { failure = String(localized: "Su GameBanana non c'è una pagina per questo gioco."); return }
            }
            if reset { page = 1; mods = [] } else { page += 1 }
            let more = try await client.mods(game: gbGame!.id, page: page, search: search)
            mods += more.filter { new in !mods.contains { $0.id == new.id } }
            failure = nil
        } catch {
            failure = String(localized: "GameBanana non risponde: riprova più tardi.")
        }
    }

    private func open(_ mod: GameBanana.Mod) async {
        opened = mod
        files = []
        fits = [:]
        guard let list = try? await client.files(mod: mod.id) else { failure = String(localized: "GameBanana non risponde: riprova più tardi."); return }
        guard opened?.id == mod.id else { return }
        files = list
        for file in list {
            let paths = (try? await client.contents(file: file.id)) ?? []
            if opened?.id == mod.id { fits[file.id] = GameBanana.fit(of: paths, titleID: titleID) }
        }
    }

    private func install(_ file: GameBanana.File, of mod: GameBanana.Mod) async {
        installing = file.id
        defer { installing = nil }
        do {
            let archive = try await client.download(file)
            defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            let store = NXMods(folder: NXGameFolder(titleID: titleID), record: NXPaths.standard.root.appendingPathComponent("mods/\(titleID).json"))
            _ = try store.add(archive, titleID: titleID, name: mod.name, label: "GameBanana · \(mod.author ?? mod.name)")
            model.message = String(localized: "\(mod.name) installata e attiva.")
            ActivityLog.write("Mod installed from GameBanana: \(mod.name) (\(file.name)) for \(titleID)")
            revision += 1
        } catch {
            failure = String(localized: "Installazione non riuscita: \(error.localizedDescription)")
        }
    }
}
