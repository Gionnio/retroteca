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

    /// Where the pad's focus is: the tile row, the hero's buttons, then (scrolling down) the game's actions and screenshots.
    enum Zone: Equatable {
        case tiles, buttons(Int), actions(Int), shots(Int)
        var inDetails: Bool { if case .actions = self { return true }; if case .shots = self { return true }; return false }
    }
    @State private var zone: Zone = .tiles
    @State private var openShot: Int?
    /// The game whose details are drawn below the first screen. It follows the chosen game only once the focus rests,
    /// because those cards read the game's files (sizes on a network disk, the built app): redrawing them on every
    /// step of the row made moving left and right stutter.
    @State private var detailsID: UUID?

    struct HomeAction {
        let symbol: String
        let title: String
        let run: () -> Void
    }

    var body: some View {
        let rows = makeRows()
        let hero = heroGame(rows)
        GeometryReader { geo in
        ZStack(alignment: .topLeading) {
            // One picture per game: the old one fades out while the new one fades in.
            ZStack {
                if let hero {
                    GameArt(game: hero, backdrop: true).ignoresSafeArea()
                        .id(hero.id)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: hero?.id)
            BackdropShade().ignoresSafeArea()
            // Further down, the game's details sit on a darker veil so the cards stay readable.
            colors.bg.opacity(zone.inDetails ? 0.6 : 0).ignoresSafeArea().animation(.easeInOut(duration: 0.3), value: zone.inDetails)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // First screen: the games on top, the chosen one's details at the bottom.
                        VStack(alignment: .leading, spacing: 0) {
                            if let row = rows.first {
                                TileRow(row: row, focusedID: hero?.id, buildChip: buildChip) { game in
                                    zone = .tiles
                                    withAnimation(.easeOut(duration: 0.15)) { model.heroID = game.id }
                                }
                                .padding(.top, 52 + 28)
                            }
                            // In a tall window the game stays close to the row: what is left goes below its buttons.
                            Spacer(minLength: 16).frame(maxHeight: 110)
                            Group {
                                if let hero {
                                    HeroView(game: hero, kicker: kicker(for: hero), focusedButton: buttonIndex) { showDetails(hero) }
                                } else {
                                    WelcomeHero()
                                }
                            }
                            .padding(.bottom, 44)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 48)
                        .frame(height: geo.size.height)
                        .id("top")
                        // Further down: the rest of the game's page.
                        if let shown = detailsID.flatMap(model.game(id:)) {
                            details(shown).padding(.horizontal, 48).padding(.bottom, 60).id("details")
                        }
                    }
                }
                .fadesUnderTopBar()
                .onChange(of: zone.inDetails) { _, down in
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(down ? "details" : "top", anchor: .top) }
                }
            }
            if let hero {
                ScreenshotViewer(title: hero.title, shots: hero.screenshots ?? [], index: $openShot)
            }
        }
        }
        .animation(.easeOut(duration: 0.18), value: openShot)
        .onChange(of: openShot) { _, index in model.viewerOpen = index != nil }
        .onDisappear { model.viewerOpen = false }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            focused = true
            // Every picture the Home page can show, decoded before it is needed.
            ArtworkCache.prefetch(rows.flatMap(\.games).flatMap { [$0.backdropURL ?? $0.coverURL, $0.coverURL] }.compactMap { $0 })
        }
        .onKeyPress(.leftArrow) { handle(.left, rows: rows) }
        .onKeyPress(.rightArrow) { handle(.right, rows: rows) }
        .onKeyPress(.upArrow) { handle(.up, rows: rows) }
        .onKeyPress(.downArrow) { handle(.down, rows: rows) }
        .onKeyPress(.return) { handle(.select, rows: rows) }
        .onKeyPress(.space) { handle(.secondary, rows: rows) }
        .onKeyPress(.escape) { handle(.back, rows: rows) }
        .onReceive(model.navigation) { command in _ = handle(command, rows: rows) }
        .onChange(of: model.heroID) { _, _ in if zone != .tiles, !zone.inDetails { zone = .tiles } }
        .task(id: hero?.id) {
            guard detailsID != hero?.id else { return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            if !Task.isCancelled { detailsID = hero?.id }
        }
    }

    private var buttonIndex: Int? { if case .buttons(let i) = zone { return i }; return nil }

    /// The hero's buttons, in order: play (or build), details, favourite.
    private func heroButtons(_ game: Game) -> [() -> Void] {
        [{ model.primaryAction(for: game) }, { showDetails(game) }, { model.toggleFavorite(game.id) }]
    }

    private func actions(_ game: Game) -> [HomeAction] {
        var list: [HomeAction] = []
        if game.nativeApp != nil {
            list.append(HomeAction(symbol: "slider.horizontal.3", title: String(localized: "Impostazioni")) { model.openOptions(game.id, tab: .settings) })
            list.append(HomeAction(symbol: "puzzlepiece.extension", title: String(localized: "Mod")) { model.openOptions(game.id, tab: .mods) })
            list.append(HomeAction(symbol: "wand.and.stars", title: String(localized: "Trucchi")) { model.openOptions(game.id, tab: .cheats) })
            list.append(HomeAction(symbol: "externaldrive", title: String(localized: "Salvataggi")) { model.openOptions(game.id, tab: .saves) })
            if model.buildStage(game) == .none {
                list.append(HomeAction(symbol: "arrow.triangle.2.circlepath", title: String(localized: "Ricostruisci")) { model.queueBuild(game) })
            }
        }
        list.append(HomeAction(symbol: "folder", title: String(localized: "Finder")) { model.revealInFinder(game) })
        list.append(HomeAction(symbol: "rectangle.portrait.and.arrow.right", title: String(localized: "Pagina gioco")) { model.open(.game(game.id)) })
        return list
    }

    private func shots(_ game: Game) -> [URL] { game.screenshots ?? [] }

    /// Down from the hero: the actions, or the screenshots when there are no actions.
    private func showDetails(_ game: Game) {
        InterfaceSound.select.play()
        detailsID = game.id
        zone = actions(game).isEmpty ? (shots(game).isEmpty ? .tiles : .shots(0)) : .actions(0)
    }

    @ViewBuilder private func details(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(game.title).font(.system(size: 22, weight: .bold)).foregroundStyle(colors.fg).padding(.top, PageLayout.top)
            HStack(spacing: 12) {
                ForEach(Array(actions(game).enumerated()), id: \.offset) { index, action in
                    ActionTile(symbol: action.symbol, title: action.title, focused: zone == .actions(index)) {
                        zone = .actions(index)
                        action.run()
                    }
                }
            }
            if !shots(game).isEmpty {
                ScreenshotRow(shots: shots(game), source: String(localized: "dal negozio Nintendo"), focused: shotIndex) { openShot = $0 }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HowItRunsCard(game: game)
                    if let app = game.nativeApp, GamesLocation.isRetrotecaApp(app), GamesLocation.missingVolume(of: app) == nil {
                        GameSpaceCard(game: game)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                SwitchBuildCard(game: game).frame(maxWidth: 620, alignment: .leading)
            }
        }
    }

    private var shotIndex: Int? { if case .shots(let i) = zone { return i }; return nil }

    /// One command, from the keyboard or the pad, for the zone that has the focus.
    private func handle(_ command: NavCommand, rows: [Row]) -> KeyPress.Result {
        guard let hero = heroGame(rows) else { return .ignored }
        if let open = openShot {
            let count = shots(hero).count
            switch command {
            case .left: openShot = max(open - 1, 0)
            case .right: openShot = min(open + 1, count - 1)
            case .back, .select: openShot = nil
            default: break
            }
            return .handled
        }
        let actionCount = actions(hero).count, shotCount = shots(hero).count
        func go(_ next: Zone) { if next != zone { InterfaceSound.move.play(); zone = next } else { InterfaceSound.blocked.play() } }
        switch (zone, command) {
        case (.tiles, .left): return move(rows, dx: -1, dy: 0)
        case (.tiles, .right): return move(rows, dx: 1, dy: 0)
        case (.tiles, .down): go(.buttons(0))
        case (.tiles, .select): model.primaryAction(for: hero)
        case (.tiles, .secondary): showDetails(hero)
        case (.buttons(let i), .left): go(.buttons(max(i - 1, 0)))
        case (.buttons(let i), .right): go(.buttons(min(i + 1, 2)))
        case (.buttons, .up), (.buttons, .back): go(.tiles)
        case (.buttons, .down): showDetails(hero)
        case (.buttons(let i), .select): heroButtons(hero)[i]()
        case (.actions(let i), .left): go(.actions(max(i - 1, 0)))
        case (.actions(let i), .right): go(.actions(min(i + 1, actionCount - 1)))
        case (.actions, .up): go(.buttons(0))
        case (.actions, .down): if shotCount > 0 { go(.shots(0)) }
        case (.actions(let i), .select): if i < actionCount { actions(hero)[i].run() }
        case (.actions, .back), (.shots, .back): go(.tiles)
        case (.shots(let i), .left): go(.shots(max(i - 1, 0)))
        case (.shots(let i), .right): go(.shots(min(i + 1, shotCount - 1)))
        case (.shots, .up): go(actionCount > 0 ? .actions(0) : .buttons(0))
        case (.shots(let i), .select): openShot = i
        default: return .ignored
        }
        return .handled
    }

    // MARK: Rows

    /// One row, like a console's home: the games played last first, then the ones ready, then the rest.
    private func makeRows() -> [Row] {
        let games = model.games
        guard !games.isEmpty else { return [] }
        let ordered = games.sorted { a, b in
            switch (a.lastPlayedAt, b.lastPlayedAt) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                if (a.nativeApp != nil) != (b.nativeApp != nil) { return a.nativeApp != nil }
                return a.addedAt > b.addedAt
            }
        }
        let title = ordered.first?.lastPlayedAt != nil ? String(localized: "Continua a giocare") : String(localized: "I tuoi giochi")
        return [Row(id: "home", title: title, games: ordered)]
    }

    /// "● Pokopia · costruzione 62%" next to the row's title while a build runs.
    private var buildChip: String? {
        guard let id = model.switchGames.buildingID, let game = model.game(id: id) else { return nil }
        let fraction = model.switchGames.builds[id]?.overallFraction ?? 0
        return String(localized: "\(game.title) · costruzione \(Int(fraction * 100))%")
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
        let target = rows[r].games[c].id
        (target == heroGame(rows)?.id && rows[r].id == focusRow ? InterfaceSound.blocked : InterfaceSound.move).play()
        focusRow = rows[r].id
        if dy != 0 { scrollTarget = rows[r].id }
        withAnimation(.easeOut(duration: 0.18)) { model.heroID = target }
        return .handled
    }
}

private struct HeroView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game
    let kicker: String
    var focusedButton: Int? = nil
    var details: () -> Void = {}

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
                PrimaryGameButton(game: game).padFocus(focusedButton == 0)
                Button { details() } label: { Label("Dettagli", systemImage: "chevron.down") }.buttonStyle(PlateaButtonStyle()).padFocus(focusedButton == 1)
                Button { model.toggleFavorite(game.id) } label: { Image(systemName: game.isFavorite ? "heart.fill" : "heart") }
                    .buttonStyle(PlateaButtonStyle()).padFocus(focusedButton == 2)
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
        let manager = model.switchGames
        switch model.buildStage(game) {
        case .building(let fraction):
            Button { model.open(.build(game.id)) } label: {
                Label(String(localized: "Costruzione \(Int(fraction * 100))%"), systemImage: "hammer")
            }
            .buttonStyle(PlateaButtonStyle(primary: true))
        case .queued(let position):
            Button { model.open(.builds) } label: { Label(String(localized: "In coda · \(position)°"), systemImage: "clock") }
                .buttonStyle(PlateaButtonStyle(primary: true))
        case .paused(let fraction):
            Button { model.resumeBuild(game) } label: { Label(String(localized: "Riprendi · \(Int(fraction * 100))%"), systemImage: "play.fill") }
                .buttonStyle(PlateaButtonStyle(primary: true))
        case .none where game.nativeApp == nil:
            Button { model.buildSwitchGame(game) } label: { Label("Costruisci per Mac", systemImage: "hammer") }
                .buttonStyle(PlateaButtonStyle(primary: true))
                .disabled(!(manager.toolchain?.isReady ?? false) || game.status == .missingFiles || !model.switchHasBase(game))
        case .none:
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
    var buildChip: String? = nil
    let choose: (Game) -> Void
    /// First tile in view, moved by the arrows (one screenful at a time).
    @State private var start = 0
    @State private var width: CGFloat = 0
    @State private var hovering = false

    /// Tiles that fit in the row (the smaller size, 14 apart).
    private var perPage: Int { max(1, Int((width + 14) / (Tile.width + 14))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(row.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(colors.fg)
                if let buildChip {
                    Button { model.open(.builds) } label: { PlateaChip(text: "● " + buildChip, tint: colors.warning) }.buttonStyle(.plain)
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(row.games) { game in
                            Tile(game: game, isFocused: game.id == focusedID) { choose(game) }.id(game.id)
                        }
                        LibraryTile()
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

    /// The chosen game at full size, the others smaller (as in the approved mockup: 14.5 to 11).
    static let focusedWidth: CGFloat = 210
    static let width: CGFloat = 160

    var body: some View {
        let width = isFocused ? Self.focusedWidth : Self.width
        ZStack(alignment: .bottomLeading) {
            GameArt(game: game)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            Text(game.title)
                .font(.system(size: isFocused ? 12.5 : 11.5, weight: .bold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
                .lineLimit(1).padding(.horizontal, 9).padding(.bottom, 7)
        }
        .saturation(dimmed ? 0.25 : 1).brightness(dimmed ? -0.15 : 0)
        .overlay { BuildOverlay(game: game) }
        .frame(width: width, height: width * 9 / 16)
        .overlay(alignment: .topTrailing) { StatusBadge(game: game) }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(isFocused ? colors.fg : .clear, lineWidth: 2.5).padding(-4))
        .shadow(color: .black.opacity(isFocused ? 0.45 : 0.25), radius: isFocused ? 14 : 2, y: isFocused ? 10 : 1)
        .contentShape(Rectangle())
        .help(subtitle.isEmpty ? game.title : "\(game.title) · \(subtitle)")
        .onTapGesture(count: 2) { model.open(.game(game.id)) }
        .onTapGesture { choose() }
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }

    /// A game without its app yet looks switched off, like one not downloaded on a console.
    private var dimmed: Bool {
        if case .building = model.buildStage(game) { return false }
        return game.nativeApp == nil
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
                Button("Impostazioni") { model.open(.settings(.general)) }
                    .buttonStyle(PlateaButtonStyle())
            }
            .padding(.top, 16)
        }
        .frame(minHeight: 270, alignment: .top)
    }
}

/// What a tile shows of the build line: queued, building (bar and %), paused, or "to build".
struct BuildOverlay: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game

    var body: some View {
        switch model.buildStage(game) {
        case .building(let fraction):
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.25)
                Text("\(Int(fraction * 100))%").font(.system(size: 18, weight: .heavy)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 4).frame(maxHeight: .infinity)
                bar(fraction, colors.accent)
            }
        case .queued(let position):
            ZStack {
                Color.black.opacity(0.45)
                Text("In coda · \(position)°").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            }
        case .paused(let fraction):
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.45)
                Label("\(Int(fraction * 100))%", systemImage: "pause.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).frame(maxHeight: .infinity)
                bar(fraction, .white.opacity(0.6))
            }
        case .none:
            if game.nativeApp == nil {
                Text("Da costruire").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(.black.opacity(0.55), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(7)
            }
        }
    }

    private func bar(_ fraction: Double, _ color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(color).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 5).padding(.horizontal, 10).padding(.bottom, 9)
    }
}

/// The last tile of the home row: the whole library.
private struct LibraryTile: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors

    var body: some View {
        Button { model.open(.grid) } label: {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2").font(.system(size: 22))
                Text("Libreria").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(colors.secondary)
            .frame(width: Tile.width, height: Tile.width * 9 / 16)
            .background(colors.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(colors.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
        .buttonStyle(.plain)
    }
}
