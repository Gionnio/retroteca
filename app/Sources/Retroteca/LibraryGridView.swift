import SwiftUI
import RetrotecaCore

/// The library as a grid of covers, like the Film page of Platea.
struct LibraryGridView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    @AppStorage("gridSort") private var sort = Sort.lastPlayed.rawValue
    @State private var filter = Filter.all
    @State private var platform: String?
    @State private var focus: Int?
    @State private var gridWidth: CGFloat = 0
    @FocusState private var searching: Bool

    enum Filter: CaseIterable { case all, toPlay, inProgress, favorites, toInstall }

    enum Sort: String, CaseIterable { case lastPlayed, title, added }

    var body: some View {
        let games = visibleGames
        ScrollViewReader { proxy in
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Libreria").font(.system(size: 26, weight: .bold)).foregroundStyle(colors.fg)
                    Text("\(games.count) giochi").foregroundStyle(colors.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(colors.secondary)
                        TextField(String(localized: "Cerca giochi"), text: $model.searchText).textFieldStyle(.plain).focused($searching).frame(width: 180)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(colors.line, lineWidth: 1.5))
                    Button { model.chooseFilesToImport() } label: { Label("Aggiungi giochi", systemImage: "plus") }
                        .buttonStyle(PlateaButtonStyle())
                }
                .background(Button("") { searching = true }.keyboardShortcut("f").opacity(0))
                filters.padding(.top, 8).padding(.bottom, !model.pendingSwitchFiles.isEmpty ? 6 : 16)
                if !model.pendingSwitchFiles.isEmpty {
                    Text(String(localized: "\(model.pendingSwitchFiles.count) aggiornamenti o DLC aspettano il loro gioco base."))
                        .font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.bottom, 14)
                        .help(model.pendingSwitchFiles.map(\.lastPathComponent).joined(separator: "\n"))
                }
                if games.isEmpty {
                    Text(model.games.isEmpty ? "La libreria è vuota: trascina qui i tuoi giochi." : "Nessun gioco con questi filtri.")
                        .foregroundStyle(colors.secondary).padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)], alignment: .leading, spacing: 22) {
                        ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                            BoxTile(game: game, isFocused: focus == index).id(game.id)
                        }
                    }
                    .background(GeometryReader { geo in Color.clear.onAppear { gridWidth = geo.size.width }.onChange(of: geo.size.width) { _, w in gridWidth = w } })
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 52 + 30)
            .padding(.bottom, 40)
        }
        .fadesUnderTopBar()
        .scrollIndicators(.automatic)
        .onAppear { ArtworkCache.prefetch(model.games.compactMap { $0.coverURL ?? $0.backdropURL }) }
        .gridNavigation(count: games.count, columns: adaptiveColumns(width: gridWidth, minimum: 150, spacing: 18), focus: $focus) { index in
            model.open(.game(games[index].id))
        }
        .onChange(of: focus) { _, index in
            if let index, games.indices.contains(index) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(games[index].id, anchor: .center) } }
        }
        .onChange(of: filter) { _, _ in focus = nil }
        }
    }

    private var visibleGames: [Game] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        let list = model.games.filter { game in
            (platform == nil || game.platformID == platform)
            && (query.isEmpty || game.title.localizedCaseInsensitiveContains(query))
            && {
                switch filter {
                case .all: return true
                case .toPlay: return game.lastPlayedAt == nil && game.status == .ready
                case .inProgress: return game.lastPlayedAt != nil
                case .favorites: return game.isFavorite
                case .toInstall: return game.status != .ready
                }
            }()
        }
        switch Sort(rawValue: sort) ?? .lastPlayed {
        case .title: return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .added: return list.sorted { $0.addedAt > $1.addedAt }
        case .lastPlayed: return list.filtered(by: .all)
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            PillButton(title: String(localized: "Tutti"), isOn: filter == .all) { filter = .all }
            PillButton(title: String(localized: "Da giocare"), isOn: filter == .toPlay) { filter = .toPlay }
            PillButton(title: String(localized: "In corso"), isOn: filter == .inProgress) { filter = .inProgress }
            PillButton(title: String(localized: "Preferiti"), isOn: filter == .favorites) { filter = .favorites }
            PillButton(title: String(localized: "Da sistemare"), isOn: filter == .toInstall) { filter = .toInstall }
            Spacer()
            if model.platformIDs.count > 1 {
            Menu {
                Button("Tutte le console") { platform = nil }
                Divider()
                ForEach(model.platformIDs, id: \.self) { id in Button(model.platformName(id)) { platform = id } }
            } label: {
                pillLabel((platform.map { model.platformName($0) } ?? String(localized: "Tutte le console")) + " ▾")
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            }
            Menu {
                Button("Ultimo avvio") { sort = Sort.lastPlayed.rawValue }
                Button("Titolo") { sort = Sort.title.rawValue }
                Button("Aggiunti di recente") { sort = Sort.added.rawValue }
            } label: {
                pillLabel(String(localized: "Ordina: \(sortName)"))
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
        }
    }

    private var sortName: String {
        switch Sort(rawValue: sort) ?? .lastPlayed {
        case .lastPlayed: return String(localized: "Ultimo avvio")
        case .title: return String(localized: "Titolo")
        case .added: return String(localized: "Aggiunti di recente")
        }
    }

    private func pillLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5)).foregroundStyle(colors.fg)
            .padding(.horizontal, 13).padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(colors.line, lineWidth: 1.5))
            .contentShape(Capsule())
    }
}

private struct BoxTile: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game
    var isFocused = false
    @State private var hovering = false

    var body: some View {
        let lifted = hovering || isFocused
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .bottomLeading) {
                GameArt(game: game, wide: false)
                if !GameArt.hasImage(game, wide: false) {
                    LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                    Text(game.title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 3, y: 1).lineLimit(3).padding(8)
                }
            }
            .saturation(game.nativeApp == nil && model.buildStage(game) == .none ? 0.25 : 1)
            .overlay { BuildOverlay(game: game) }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { StatusBadge(game: game) }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(lifted ? colors.fg : .clear, lineWidth: 2.5).padding(-3))
            .shadow(color: .black.opacity(0.3), radius: lifted ? 10 : 3, y: lifted ? 6 : 2)
            .scaleEffect(isFocused ? 1.04 : 1)
            Text(game.title).font(.system(size: 12)).foregroundStyle(colors.fg).lineLimit(1).padding(.top, 6)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(colors.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.open(.game(game.id)) }
        .animation(.easeOut(duration: 0.15), value: lifted)
    }

    private var subtitle: String {
        switch game.status {
        case .ready: return model.platformName(game.platformID)
        case .needsEngine: return String(localized: "Da costruire")
        case .missingFiles: return String(localized: "File non trovati")
        case .unrecognized: return String(localized: "Console da riconoscere")
        }
    }
}
