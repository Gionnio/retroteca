import SwiftUI
import RetrotecaCore

/// Entry page: the focused game in a full-window hero, rows of tiles below.
/// Arrows move between tiles, Return plays (or builds the game), Space opens the game page.
struct VetrinaView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    @FocusState private var focused: Bool
    /// The row of the chosen tile: a game listed in two rows is chosen in one of them only.
    @State private var focusRow: String?
    /// Set by arrow keys and the controller only: a click never scrolls the rows.
    @State private var scrollTarget: String?

    struct Row: Identifiable {
        let id: String
        let title: String
        let games: [Game]
    }

    var body: some View {
        let rows = makeRows()
        let hero = heroGame(rows)
        ZStack(alignment: .topLeading) {
            if let hero {
                GameArt(game: hero, backdrop: true).ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.35), value: hero.id)
            }
            BackdropShade().ignoresSafeArea()
            // As in Platea: the hero stays put, only the rows scroll, following the focused tile.
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let hero {
                        HeroView(game: hero, kicker: kicker(for: hero))
                    } else {
                        WelcomeHero()
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 52 + 36)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                TileRow(row: row, focusedID: hero.flatMap { activeRow(rows, hero: $0) == row.id ? $0.id : nil }) { game in
                                    focusRow = row.id
                                    withAnimation(.easeOut(duration: 0.15)) { model.heroID = game.id }
                                }
                                .id(row.id)
                            }
                            Spacer(minLength: 40)
                        }
                        .padding(.horizontal, 48)
                    }
                    .onChange(of: scrollTarget) { _, id in
                        guard let id else { return }
                        // Only as far as needed to show the row.
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id) }
                        scrollTarget = nil
                    }
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06)], startPoint: .top, endPoint: .bottom))
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { move(rows, dx: -1, dy: 0) }
        .onKeyPress(.rightArrow) { move(rows, dx: 1, dy: 0) }
        .onKeyPress(.upArrow) { move(rows, dx: 0, dy: -1) }
        .onKeyPress(.downArrow) { move(rows, dx: 0, dy: 1) }
        .onKeyPress(.return) {
            guard let hero else { return .ignored }
            primaryAction(for: hero)
            return .handled
        }
        .onKeyPress(.space) {
            guard let hero else { return .ignored }
            model.open(.game(hero.id))
            return .handled
        }
        .onReceive(model.navigation) { command in
            switch command {
            case .left: _ = move(rows, dx: -1, dy: 0)
            case .right: _ = move(rows, dx: 1, dy: 0)
            case .up: _ = move(rows, dx: 0, dy: -1)
            case .down: _ = move(rows, dx: 0, dy: 1)
            case .select: if let hero { model.primaryAction(for: hero) }
            case .secondary: if let hero { model.open(.game(hero.id)) }
            default: break
            }
        }
    }

    // MARK: Rows

    private func makeRows() -> [Row] {
        let games = model.games
        var rows: [Row] = []
        let played = games.filter { $0.lastPlayedAt != nil }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        if !played.isEmpty { rows.append(Row(id: "played", title: String(localized: "Continua a giocare"), games: played)) }
        let fresh = games.filter { $0.status == .ready && $0.lastPlayedAt == nil }.sorted { $0.addedAt > $1.addedAt }
        if !fresh.isEmpty { rows.append(Row(id: "fresh", title: String(localized: "Pronti da giocare"), games: fresh)) }
        let favorites = games.filter(\.isFavorite)
        if !favorites.isEmpty { rows.append(Row(id: "favorites", title: String(localized: "Preferiti"), games: favorites)) }
        let built = games.filter { $0.nativeApp != nil }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if built.count > played.count { rows.append(Row(id: "built", title: String(localized: "Tutti i giochi costruiti"), games: built)) }
        let toFix = games.filter { $0.status != .ready }
        if !toFix.isEmpty { rows.append(Row(id: "fix", title: String(localized: "Da sistemare"), games: toFix)) }
        return rows
    }

    private func heroGame(_ rows: [Row]) -> Game? {
        if let id = model.heroID, let game = model.game(id: id) { return game }
        return rows.first?.games.first
    }

    private func kicker(for game: Game) -> String {
        switch game.status {
        case .needsEngine: return String(localized: "Da costruire")
        case .missingFiles: return String(localized: "File non trovati")
        case .unrecognized: return String(localized: "Console da riconoscere")
        case .ready: return game.lastPlayedAt != nil ? String(localized: "Continua a giocare") : String(localized: "Pronto da giocare")
        }
    }

    private func primaryAction(for game: Game) {
        if game.status == .ready {
            model.play(game)
        } else {
            model.open(.game(game.id))
        }
    }

    /// The row the chosen tile is in: the one last chosen, else the first that lists the game.
    private func activeRow(_ rows: [Row], hero: Game) -> String? {
        if let focusRow, rows.first(where: { $0.id == focusRow })?.games.contains(where: { $0.id == hero.id }) == true { return focusRow }
        return rows.first { $0.games.contains { $0.id == hero.id } }?.id
    }

    /// Moves the focus like a TV remote: the same position in the next row, clamped.
    private func move(_ rows: [Row], dx: Int, dy: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        var r = 0, c = 0
        if let hero = heroGame(rows), let rowID = activeRow(rows, hero: hero), let ri = rows.firstIndex(where: { $0.id == rowID }) {
            r = ri
            c = rows[ri].games.firstIndex { $0.id == hero.id } ?? 0
        }
        r = min(max(r + dy, 0), rows.count - 1)
        c = min(max(c + dx, 0), rows[r].games.count - 1)
        focusRow = rows[r].id
        if dy != 0 { scrollTarget = rows[r].id }
        withAnimation(.easeOut(duration: 0.18)) { model.heroID = rows[r].games[c].id }
        return .handled
    }
}

private struct HeroView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game
    let kicker: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(text: kicker)
            Text(game.title)
                .font(.system(size: 46, weight: .bold)).tracking(-0.8)
                .foregroundStyle(colors.fg)
                .lineLimit(2).minimumScaleFactor(0.7)
                .padding(.top, 8).padding(.bottom, 10)
            Text(meta).font(.system(size: 13)).foregroundStyle(colors.fg.opacity(0.9))
            HStack(spacing: 6) {
                GameStatusChip(game: game)
                PlateaChip(text: game.kind.label)
                if game.files.count > 1 { PlateaChip(text: String(localized: "\(game.files.count) file")) }
            }
            .padding(.vertical, 10)
            Text(description).font(.system(size: 13)).foregroundStyle(colors.secondary)
                .lineLimit(2, reservesSpace: true).frame(maxWidth: 520, alignment: .leading)
            HStack(spacing: 10) {
                PrimaryGameButton(game: game)
                Button("Dettagli") { model.open(.game(game.id)) }.buttonStyle(PlateaButtonStyle())
                Button { model.toggleFavorite(game.id) } label: { Image(systemName: game.isFavorite ? "heart.fill" : "heart") }
                    .buttonStyle(PlateaButtonStyle())
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: 600, alignment: .leading)
        // Fixed height, anchored at the bottom: a one-line or two-line title never moves the buttons and the rows.
        .frame(height: 300, alignment: .bottomLeading)
    }

    private var meta: String {
        var parts = [model.platformName(game.platformID)]
        if let year = game.year { parts.append(String(year)) }
        if game.playTime >= 60 { parts.append(String(localized: "\(formatPlayTime(game.playTime)) giocate")) }
        if let last = game.lastPlayedAt { parts.append(last.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    private var description: String {
        if let summary = game.summary, !summary.isEmpty, game.status == .ready || game.kind == .switchNative { return summary }
        switch game.status {
        case .ready:
            let engine = model.runnerName(for: game) ?? game.kind.label
            return game.lastPlayedAt != nil
                ? String(localized: "Riprendi · \(engine)")
                : String(localized: "Pronto · \(engine)")
        case .needsEngine: return String(localized: "Da costruire come app Mac dal tuo gioco.")
        case .missingFiles: return String(localized: "File non trovati.")
        case .unrecognized: return String(localized: "Gioco da riconoscere.")
        }
    }
}

/// Green "✓ Pronto · App Mac nativa", orange or red when something is missing.
struct GameStatusChip: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game

    var body: some View {
        statusChip
    }

    @ViewBuilder private var statusChip: some View {
        if let app = game.nativeApp, GamesLocation.missingVolume(of: app) != nil {
            PlateaChip(text: String(localized: "Disco non collegato"), tint: colors.warning)
        } else {
            readiness
        }
    }

    @ViewBuilder private var readiness: some View {
        switch game.status {
        case .ready:
            PlateaChip(text: "✓ " + String(localized: "Pronto") + (model.runnerName(for: game).map { " · \($0)" } ?? ""), tint: colors.ok)
        case .needsEngine: PlateaChip(text: String(localized: "Da costruire"), tint: colors.warning)
        case .missingFiles: PlateaChip(text: String(localized: "File non trovati"), tint: .red)
        case .unrecognized: PlateaChip(text: String(localized: "Console da riconoscere"), tint: .blue)
        }
    }
}

/// "Gioca", or "Costruisci per Mac" while the game has no app yet.
struct PrimaryGameButton: View {
    @EnvironmentObject var model: AppModel
    let game: Game

    var body: some View {
        if game.nativeApp == nil || model.switchGames.buildingID == game.id {
            let manager = model.switchGames
            if manager.buildingID == game.id {
                let state = manager.builds[game.id] ?? NXBuildState()
                Button { model.open(.build(game.id)) } label: {
                    Label(String(localized: "Costruzione \(state.current ?? 0)/\(max(state.stageCount, 1)) · \(Int(state.overallFraction * 100))%"), systemImage: "hammer")
                }
                .buttonStyle(PlateaButtonStyle(primary: true))
            } else {
                Button { model.buildSwitchGame(game) } label: { Label("Costruisci per Mac", systemImage: "hammer") }
                    .buttonStyle(PlateaButtonStyle(primary: true))
                    .disabled(!(manager.toolchain?.isReady ?? false) || manager.isBusy || game.status == .missingFiles || !model.switchHasBase(game))
            }
        } else {
            Button { model.play(game) } label: {
                Label(model.runningGameID == game.id ? String(localized: "In gioco…") : String(localized: "Gioca"), systemImage: "play.fill")
            }
            .buttonStyle(PlateaButtonStyle(primary: true))
            .disabled(game.status != .ready || model.runningGameID != nil || game.nativeApp.flatMap(GamesLocation.missingVolume(of:)) != nil)
        }
    }
}

private struct TileRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let row: VetrinaView.Row
    /// The chosen game, when the chosen tile is in this row.
    let focusedID: UUID?
    let choose: (Game) -> Void
    /// First tile in view, moved by the arrows (one screenful at a time).
    @State private var start = 0
    @State private var width: CGFloat = 0
    @State private var hovering = false

    /// Tiles that fit in the row (210 wide, 14 apart).
    private var perPage: Int { max(1, Int((width + 14) / 224)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(colors.fg)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(row.games) { game in
                            Tile(game: game, isFocused: game.id == focusedID) { choose(game) }.id(game.id)
                        }
                    }
                    .padding(.vertical, 12).padding(.horizontal, 10)
                }
                // The focused tile grows and gets an outline: room for it without moving the row.
                .padding(.horizontal, -10)
                .background(GeometryReader { geo in Color.clear.onAppear { width = geo.size.width }.onChange(of: geo.size.width) { _, w in width = w } })
                // Arrows for the mouse: shown on hover when there is more to see on that side.
                .overlay(alignment: .leading) {
                    if hovering && start > 0 { arrow("chevron.left") { page(-1, proxy) } }
                }
                .overlay(alignment: .trailing) {
                    if hovering && start + perPage < row.games.count { arrow("chevron.right") { page(1, proxy) } }
                }
                .onHover { hovering = $0 }
                // Only as far as needed to show the chosen tile: a tile already in view does not move.
                .onChange(of: focusedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                    // Keep the arrows in step with moves from the keyboard or a controller.
                    if let index = row.games.firstIndex(where: { $0.id == id }) {
                        if index < start { start = index } else if index >= start + perPage { start = index - perPage + 1 }
                    }
                }
            }
        }
        .padding(.top, 22)
    }

    private func page(_ direction: Int, _ proxy: ScrollViewProxy) {
        start = min(max(start + direction * perPage, 0), max(row.games.count - perPage, 0))
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(row.games[start].id, anchor: .leading) }
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(colors.fg)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(colors.line))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.bottom, 34)
        .transition(.opacity)
    }
}

private struct Tile: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game
    let isFocused: Bool
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .bottomLeading) {
                GameArt(game: game)
                if !GameArt.hasImage(game) {
                    LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                    Text(game.title)
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                        .lineLimit(2).padding(10)
                }
            }
            .frame(width: 210, height: 118)
            .overlay(alignment: .topTrailing) { StatusBadge(game: game) }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(isFocused ? colors.fg : .clear, lineWidth: 2.5).padding(-4))
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0.25), radius: isFocused ? 14 : 2, y: isFocused ? 10 : 1)
            .scaleEffect(isFocused ? 1.04 : 1)
            .offset(y: isFocused ? -4 : 0)
            Text(game.title).font(.system(size: 12.5)).foregroundStyle(colors.fg).lineLimit(1).padding(.top, 5)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(colors.secondary).lineLimit(1)
        }
        .frame(width: 210)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(.game(game.id)) }
        .onTapGesture { choose() }
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }

    private var subtitle: String {
        var parts = [model.platformName(game.platformID)]
        if game.playTime >= 60 { parts.append(formatPlayTime(game.playTime)) }
        return parts.joined(separator: " · ")
    }
}

/// Empty library: an invitation to drop games, in the same hero style.
private struct WelcomeHero: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(text: String(localized: "Benvenuto"))
            Text("Trascina qui i tuoi giochi")
                .font(.system(size: 46, weight: .bold)).tracking(-0.8).foregroundStyle(colors.fg)
                .padding(.top, 8).padding(.bottom, 10)
            Text("Aggiungi i dump dei giochi Switch che possiedi. Giochi, firmware e chiavi non sono inclusi.")
                .font(.system(size: 13)).foregroundStyle(colors.secondary).frame(maxWidth: 520, alignment: .leading)
            HStack(spacing: 10) {
                Button { model.chooseFilesToImport() } label: { Label("Aggiungi giochi…", systemImage: "plus") }
                    .buttonStyle(PlateaButtonStyle(primary: true))
                Button("Motori") { model.open(.engines) }
                    .buttonStyle(PlateaButtonStyle())
            }
            .padding(.top, 16)
        }
        .frame(minHeight: 270, alignment: .top)
    }
}
