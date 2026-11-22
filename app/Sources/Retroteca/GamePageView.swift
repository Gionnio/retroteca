import SwiftUI
import RetrotecaCore

/// The game page, like the film page of Platea: full-window art, title, actions and the "COME GIRA" card.
struct GamePageView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let gameID: UUID
    @FocusState private var focused: Bool
    @State private var confirmRemove = false
    /// The screenshot raised by keyboard or controller moves, and the one open over the whole window.
    @State private var focusedShot: Int?
    @State private var openShot: Int?

    var body: some View {
        if let game = model.game(id: gameID) {
            ZStack(alignment: .topLeading) {
                GameArt(game: game, backdrop: true).ignoresSafeArea()
                BackdropShade().ignoresSafeArea()
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            BackButton(viewerOpen: openShot != nil)
                            Kicker(text: "\(model.platformName(game.platformID)) · \(game.kind.label)")
                            if let logo = game.logoURL.flatMap({ ArtworkCache.image(at: $0) }) {
                                Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                                    .frame(maxWidth: 420, maxHeight: 150, alignment: .leading)
                                    .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
                                    .accessibilityLabel(game.title)
                                    .padding(.top, 12).padding(.bottom, 14)
                            } else {
                                Text(game.title)
                                    .font(.system(size: 40, weight: .bold)).tracking(-0.6)
                                    .foregroundStyle(colors.fg).lineLimit(2).minimumScaleFactor(0.7)
                                    .padding(.top, 8).padding(.bottom, 10)
                            }
                            Text(meta(game)).font(.system(size: 13)).foregroundStyle(colors.fg.opacity(0.9))
                            if model.switchNeedsRebuild(game) {
                                PlateaChip(text: String(localized: "Aggiornamento da costruire"), tint: colors.warning).padding(.top, 8)
                            }
                            if let summary = game.summary, !summary.isEmpty {
                                Text(summary).font(.system(size: 13)).foregroundStyle(colors.secondary)
                                    .lineLimit(4).frame(maxWidth: 560, alignment: .leading).padding(.top, 8)
                            }
                            HStack(spacing: 10) {
                                PrimaryGameButton(game: game)
                                if game.nativeApp != nil, model.buildStage(game) == .none {
                                    Button { model.queueBuild(game) } label: { Label("Ricostruisci", systemImage: "arrow.triangle.2.circlepath") }
                                        .buttonStyle(PlateaButtonStyle())
                                        .disabled(game.status == .missingFiles || !model.switchHasBase(game))
                                }
                                Button { model.toggleFavorite(game.id) } label: { Image(systemName: game.isFavorite ? "heart.fill" : "heart") }
                                    .buttonStyle(PlateaButtonStyle())
                            }
                            .padding(.top, 16)
                            // Console-style actions: one tile each, under the main buttons.
                            HStack(spacing: 12) {
                                if game.nativeApp != nil {
                                    ActionTile(symbol: "slider.horizontal.3", title: String(localized: "Impostazioni")) { model.openOptions(game.id, tab: .settings) }
                                    ActionTile(symbol: "puzzlepiece.extension", title: String(localized: "Mod")) { model.openOptions(game.id, tab: .mods) }
                                    ActionTile(symbol: "wand.and.stars", title: String(localized: "Trucchi")) { model.openOptions(game.id, tab: .cheats) }
                                    ActionTile(symbol: "externaldrive", title: String(localized: "Salvataggi")) { model.openOptions(game.id, tab: .saves) }
                                }
                                if let shots = game.screenshots, !shots.isEmpty {
                                    ActionTile(symbol: "photo.on.rectangle", title: String(localized: "Schermate")) { openShot = 0 }
                                }
                                ActionTile(symbol: "folder", title: String(localized: "Finder")) { model.revealInFinder(game) }
                                ActionTile(symbol: "minus.circle", title: String(localized: "Togli")) { confirmRemove = true }
                            }
                            .padding(.top, 18)
                            HowItRunsCard(game: game).padding(.top, 18)
                            if let app = game.nativeApp, GamesLocation.isRetrotecaApp(app), GamesLocation.missingVolume(of: app) == nil {
                                GameSpaceCard(game: game).padding(.top, 14)
                            }
                            SwitchBuildCard(game: game).padding(.top, 14)
                        }
                        .frame(maxWidth: 680, alignment: .leading)
                        if let shots = game.screenshots, !shots.isEmpty {
                            ScreenshotRow(shots: shots, source: String(localized: "dal negozio Nintendo"),
                                          focused: focusedShot) { openShot = $0 }
                                .padding(.top, 24)
                        }
                        Spacer(minLength: 40)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 48)
                    .padding(.top, 52 + 24)
                }
                .fadesUnderTopBar()
                ScreenshotViewer(title: game.title, shots: game.screenshots ?? [], index: $openShot)
            }
            .animation(.easeOut(duration: 0.18), value: openShot)
            .onChange(of: openShot) { _, index in model.viewerOpen = index != nil }
            .onDisappear { model.viewerOpen = false }
            .confirmationDialog("Togliere \(game.title) dalla libreria?", isPresented: $confirmRemove) {
                Button("Togli dalla libreria", role: .destructive) { model.remove(game.id); model.back() }
            } message: {
                Text("I file restano dove sono.")
            }
            .focusable().focused($focused).focusEffectDisabled()
            .onAppear { focused = true }
            .onKeyPress(.return) {
                if let shot = openShot ?? focusedShot { openShot = shot } else { model.primaryAction(for: game) }
                return .handled
            }
            .onKeyPress(.leftArrow) { move(-1, in: game) }
            .onKeyPress(.rightArrow) { move(1, in: game) }
            .onKeyPress(.downArrow) { move(0, in: game, down: true) }
            .onKeyPress(.upArrow) { if openShot == nil && focusedShot != nil { focusedShot = nil; return .handled }; return .ignored }
            .onReceive(model.navigation) { command in
                switch command {
                case .back: openShot = nil
                case .left, .previousPage: _ = move(-1, in: game)
                case .right, .nextPage: _ = move(1, in: game)
                case .down: _ = move(0, in: game, down: true)
                case .up: if openShot == nil { focusedShot = nil }
                case .select:
                    if let shot = openShot ?? focusedShot { openShot = shot } else { model.primaryAction(for: game) }
                case .secondary:
                    if game.nativeApp != nil { model.open(.options(game.id)) } else { model.toggleFavorite(game.id) }
                default: break
                }
            }
        } else {
            Color.clear.onAppear { model.closeGamePage() }
        }
    }

    /// Left and right walk the screenshots (the open one, or the raised one); down raises the first.
    private func move(_ direction: Int, in game: Game, down: Bool = false) -> KeyPress.Result {
        let count = game.screenshots?.count ?? 0
        guard count > 0 else { return .ignored }
        if let open = openShot {
            openShot = min(max(open + direction, 0), count - 1)
        } else if down {
            guard focusedShot == nil else { return .ignored }
            focusedShot = 0
        } else if let focused = focusedShot {
            focusedShot = min(max(focused + direction, 0), count - 1)
        } else {
            return .ignored
        }
        return .handled
    }

    private func meta(_ game: Game) -> String {
        var parts: [String] = []
        if let year = game.year { parts.append(String(year)) }
        if let publisher = game.publisher { parts.append(publisher) }
        if let genres = game.genres, !genres.isEmpty { parts.append(genres.prefix(2).joined(separator: ", ")) }
        parts.append(game.playTime >= 60 ? String(localized: "\(formatPlayTime(game.playTime)) giocate") : String(localized: "Mai giocato"))
        if let last = game.lastPlayedAt { parts.append(String(localized: "ultimo avvio \(last.formatted(.relative(presentation: .named)))")) }
        if game.isFavorite { parts.append("★ " + String(localized: "preferito")) }
        return parts.joined(separator: " · ")
    }
}

/// Platea's "Scheda tecnica", for games: engine, files, play time; the console choice when unrecognized.
private struct HowItRunsCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("COME GIRA").font(.system(size: 10.5, weight: .semibold)).tracking(1.8).foregroundStyle(colors.secondary)
                Spacer()
                GameStatusChip(game: game)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    key("Motore"); value(engineText)
                    key("Console"); value(model.platformName(game.platformID))
                }
                GridRow {
                    key("File"); value(game.files.first.map { $0.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "—")
                    key("Dimensione"); value(game.status == .missingFiles ? "—" : ByteCountFormatter.string(fromByteCount: game.size, countStyle: .file))
                }
                GridRow {
                    key("Tempo"); value(game.playTime >= 60 ? formatPlayTime(game.playTime) : "—")
                    key("Aggiunto"); value(game.addedAt.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.line))
    }

    private var engineText: String {
        model.runnerName(for: game) ?? game.kind.label
    }

    private func key(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(colors.secondary)
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(colors.fg).lineLimit(1).truncationMode(.middle)
    }
}

/// Wraps pills onto several lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// One action of the game page, as a glass tile.
private struct ActionTile: View {
    @Environment(\.platea) private var colors
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol).font(.system(size: 19))
                Spacer()
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(colors.fg)
            .padding(12)
            .frame(width: 104, height: 78, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hovering ? colors.fg : colors.line, lineWidth: hovering ? 2 : 1))
            .scaleEffect(hovering ? 1.04 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
