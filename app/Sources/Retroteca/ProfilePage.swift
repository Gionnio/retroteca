import SwiftUI
import UniformTypeIdentifiers
import RetrotecaCore

/// The player's name and picture, kept in the app's settings on this Mac.
enum Profile {
    static let nameKey = "profileName"
    /// "game:<id>" for a game's cover, "photo:<file>" for a picture from the Mac, empty for the initial.
    static let pictureKey = "profilePicture"

    static var defaultName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    }

    static func name(_ stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : trimmed
    }

    static func photoURL(_ file: String) -> URL {
        LibraryStore.defaultDirectory.appendingPathComponent(file)
    }

    /// Copies a picture chosen on the Mac next to the library (a new name each time, so the image cache never shows the old one).
    static func importPhoto(from source: URL, replacing old: String) -> String? {
        let file = "profile-\(UUID().uuidString.prefix(8)).\(source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased())"
        do {
            try FileManager.default.createDirectory(at: LibraryStore.defaultDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: photoURL(file))
        } catch { return nil }
        if old.hasPrefix("photo:") { try? FileManager.default.removeItem(at: photoURL(String(old.dropFirst(6)))) }
        return "photo:" + file
    }
}

/// The profile picture in a circle: a game's cover, a photo, or the initial on the accent colour.
struct ProfileAvatar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    @AppStorage(Profile.nameKey) private var name = ""
    @AppStorage(Profile.pictureKey) private var picture = ""
    let size: CGFloat
    /// Shows this choice instead of the saved one (the picker's circles).
    var choice: String?

    var body: some View {
        let current = choice ?? picture
        ZStack {
            Circle().fill(LinearGradient(colors: [colors.accent, colors.accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(String(Profile.name(name).prefix(1)).uppercased())
                .font(.system(size: size * 0.43, weight: .bold)).foregroundStyle(.white)
            if current.hasPrefix("game:"), let id = UUID(uuidString: String(current.dropFirst(5))), let game = model.game(id: id) {
                GameArt(game: game, wide: false)
            } else if current.hasPrefix("photo:"), let image = ArtworkCache.image(at: Profile.photoURL(String(current.dropFirst(6)))) {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(size > 60 ? 0.85 : 0.35), lineWidth: size > 60 ? 4 : 1.5))
    }
}

/// The profile: picture, name and pad on the left; the library's numbers, the most played games, the week and the last games on the right.
struct ProfilePageView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    @AppStorage(Profile.nameKey) private var name = ""
    @AppStorage(Profile.pictureKey) private var picture = ""

    enum Zone: Equatable { case picture, most(Int), recent(Int) }
    @State private var zone: Zone = .picture
    @State private var picking = false
    @State private var editingName = false
    @State private var draftName = ""
    @FocusState private var focused: Bool

    private var mostPlayed: [Game] {
        Array(model.games.filter { $0.playTime >= 60 }.sorted { $0.playTime > $1.playTime }.prefix(4))
    }

    private var recent: [Game] {
        Array(model.games.filter { $0.lastPlayedAt != nil }.sorted { $0.lastPlayedAt! > $1.lastPlayedAt! }.prefix(3))
    }

    var body: some View {
        let backdrop = mostPlayed.first ?? recent.first
        ZStack(alignment: .topLeading) {
            if let backdrop {
                GameArt(game: backdrop, backdrop: true).ignoresSafeArea().blur(radius: 16).scaleEffect(1.06)
            }
            // The same veil as the Home, in the palette's colour, and a little more so the cards on the right stay readable.
            colors.bg.opacity(0.35).ignoresSafeArea()
            BackdropShade().ignoresSafeArea()
            HStack(alignment: .top, spacing: 40) {
                who.frame(width: 280)
                VStack(alignment: .leading, spacing: 16) {
                    stats
                    HStack(alignment: .top, spacing: 14) {
                        mostCard.frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 14) {
                            weekCard
                            recentCard
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 48).padding(.top, PageLayout.top + 16).padding(.bottom, 50)
            if picking {
                AvatarPicker(picture: $picture) { picking = false; focused = true }
                    .transition(.opacity).zIndex(5)
            }
        }
        .animation(.easeOut(duration: 0.18), value: picking)
        .onChange(of: picking) { _, open in model.viewerOpen = open }
        .onDisappear { model.viewerOpen = false }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { key(.left) }
        .onKeyPress(.rightArrow) { key(.right) }
        .onKeyPress(.upArrow) { key(.up) }
        .onKeyPress(.downArrow) { key(.down) }
        .onKeyPress(.return) { key(.select) }
        .onKeyPress(.space) { key(.secondary) }
        .onKeyPress(.escape) { if picking { return key(.back) }; model.back(); return .handled }
        .onReceive(model.navigation) { command in _ = handle(command) }
        .alert(String(localized: "Nome"), isPresented: $editingName) {
            TextField(Profile.defaultName, text: $draftName)
            Button(String(localized: "Salva")) { name = draftName }
            Button(String(localized: "Annulla"), role: .cancel) {}
        }
    }

    // MARK: Left column

    private var who: some View {
        VStack(spacing: 10) {
            Button { picking = true } label: {
                ProfileAvatar(size: 150)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 32, height: 32).background(.white, in: Circle()).offset(x: -4, y: -4)
                    }
            }
            .buttonStyle(.plain)
            .padFocus(zone == .picture, radius: 75)
            Text(Profile.name(name)).font(.system(size: 32, weight: .bold)).foregroundStyle(colors.fg).lineLimit(1).padding(.top, 6)
            if let since = model.games.map(\.addedAt).min() {
                Text("Su Retroteca dal \(since.formatted(.dateTime.day().month(.wide).year()))")
                    .font(.system(size: 12.5)).foregroundStyle(colors.secondary)
            }
            HStack(spacing: 8) {
                Button(String(localized: "Cambia immagine")) { picking = true }.buttonStyle(PlateaButtonStyle()).controlSize(.small)
                Button(String(localized: "Nome")) { draftName = name; editingName = true }.buttonStyle(PlateaButtonStyle()).controlSize(.small)
            }
            .padding(.top, 6)
            if let pad = PadStatus.current {
                HStack(spacing: 6) {
                    Image(systemName: "gamecontroller.fill")
                    Text(pad.name + (pad.battery.map { " · \(Int($0 * 100))%" } ?? ""))
                }
                .font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Right column

    private var stats: some View {
        let total = model.games.reduce(0) { $0 + $1.playTime }
        let items: [(String, String)] = [
            (total >= 60 ? formatPlayTime(total) : String(localized: "0 min"), String(localized: "tempo di gioco")),
            ("\(model.games.filter { $0.lastPlayedAt != nil }.count)", String(localized: "giochi avviati")),
            ("\(model.games.filter { $0.nativeApp != nil }.count)", String(localized: "pronti da giocare")),
            ("\(model.games.count)", String(localized: "in libreria")),
        ]
        return HStack(spacing: 12) {
            ForEach(items, id: \.1) { value, label in
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).font(.system(size: 26, weight: .bold)).foregroundStyle(colors.fg).lineLimit(1).minimumScaleFactor(0.6)
                    Text(label).font(.system(size: 11.5)).foregroundStyle(colors.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
            }
        }
    }

    private var mostCard: some View {
        let top = mostPlayed
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle(String(localized: "GIOCATI DI PIÙ"))
            if top.isEmpty {
                Text("Ancora nessuna partita.").font(.system(size: 13)).foregroundStyle(colors.secondary)
            }
            ForEach(Array(top.enumerated()), id: \.element.id) { index, game in
                Button { model.open(.game(game.id)) } label: {
                    HStack(spacing: 12) {
                        GameArt(game: game, wide: false).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(game.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.fg).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(formatPlayTime(game.playTime)).font(.system(size: 12)).foregroundStyle(colors.secondary).monospacedDigit()
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(colors.fg.opacity(0.12))
                                    Capsule().fill(colors.accent).frame(width: max(6, geo.size.width * game.playTime / max(top[0].playTime, 1)))
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                    .padding(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padFocus(zone == .most(index), radius: 10)
            }
        }
        .padding(16)
        .glassCard()
    }

    private var weekCard: some View {
        let week = model.playLog.week()
        let longest = max(week.map(\.time).max() ?? 0, 1)
        let total = week.reduce(0) { $0 + $1.time }
        let days = week.filter { $0.time > 0 }.count
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle(String(localized: "QUESTA SETTIMANA"))
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(week.enumerated()), id: \.offset) { index, entry in
                    VStack(spacing: 5) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(index == week.count - 1 ? colors.accent : colors.fg.opacity(0.22))
                            .frame(height: entry.time > 0 ? max(6, 70 * entry.time / longest) : 3)
                        Text(entry.day.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 10)).foregroundStyle(colors.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 92)
            Text(total >= 60 ? String(localized: "\(formatPlayTime(total)) in \(days) giorni") : String(localized: "Nessuna partita questa settimana."))
                .font(.system(size: 11.5)).foregroundStyle(colors.secondary)
        }
        .padding(16)
        .glassCard()
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(String(localized: "ULTIME PARTITE"))
            if recent.isEmpty {
                Text("Ancora nessuna partita.").font(.system(size: 13)).foregroundStyle(colors.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, game in
                    Button { model.open(.game(game.id)) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            GameArt(game: game).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
                                .padFocus(zone == .recent(index), radius: 8)
                            Text(game.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(colors.fg).lineLimit(1)
                            if let last = game.lastPlayedAt {
                                Text(last.formatted(.dateTime.day().month(.abbreviated))).font(.system(size: 10.5)).foregroundStyle(colors.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .glassCard()
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).tracking(1.8).foregroundStyle(colors.secondary)
    }

    // MARK: Pad

    /// Keys reach the page, which holds the focus: while the picker is open they go to it like the pad's buttons.
    private func key(_ command: NavCommand) -> KeyPress.Result {
        if picking { model.navigation.send(command); return .handled }
        return handle(command)
    }

    private func handle(_ command: NavCommand) -> KeyPress.Result {
        if picking { return .ignored }
        let most = mostPlayed.count, last = recent.count
        func go(_ next: Zone) { if next != zone { InterfaceSound.move.play(); zone = next } else { InterfaceSound.blocked.play() } }
        switch (zone, command) {
        case (.picture, .right): if most > 0 { go(.most(0)) } else if last > 0 { go(.recent(0)) } else { go(zone) }
        case (.picture, .select), (_, .secondary): InterfaceSound.select.play(); picking = true
        case (.most(let i), .up): go(.most(max(i - 1, 0)))
        case (.most(let i), .down): go(.most(min(i + 1, most - 1)))
        case (.most, .left): go(.picture)
        case (.most, .right): if last > 0 { go(.recent(0)) } else { go(zone) }
        case (.most(let i), .select): if i < most { model.open(.game(mostPlayed[i].id)) }
        case (.recent(let i), .left): if i > 0 { go(.recent(i - 1)) } else if most > 0 { go(.most(0)) } else { go(.picture) }
        case (.recent(let i), .right): go(.recent(min(i + 1, last - 1)))
        case (.recent(let i), .select): if i < last { model.open(.game(recent[i].id)) }
        default: return .ignored
        }
        return .handled
    }
}

/// Choosing the profile picture: the covers of the library's games, a photo from the Mac, or the initial.
private struct AvatarPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    @Binding var picture: String
    let close: () -> Void
    @State private var focus = 0
    private let columns = 7

    private var choices: [String] {
        model.games.filter { $0.coverURL != nil }.prefix(19).map { "game:\($0.id.uuidString)" } + ["photo", ""]
    }

    var body: some View {
        let all = choices
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 6) {
                Text("Immagine del profilo").font(.system(size: 22, weight: .bold)).foregroundStyle(colors.fg)
                Text("Dai tuoi giochi, una tua foto, o l'iniziale.").font(.system(size: 13)).foregroundStyle(colors.secondary).padding(.bottom, 12)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 16), count: columns), spacing: 16) {
                    ForEach(Array(all.enumerated()), id: \.offset) { index, choice in
                        Button { choose(choice) } label: { circle(choice) }
                            .buttonStyle(.plain)
                            .padFocus(index == focus, radius: 42)
                    }
                }
            }
            .fixedSize()
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(colors.line))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        }
        .onAppear { focus = all.firstIndex(of: picture) ?? (picture.hasPrefix("photo:") ? all.count - 2 : all.count - 1) }
        .onReceive(model.navigation) { command in
            switch command {
            case .left: move(-1, all.count)
            case .right: move(1, all.count)
            case .up: move(-columns, all.count)
            case .down: move(columns, all.count)
            case .select: choose(all[focus])
            case .back: InterfaceSound.back.play(); close()
            default: break
            }
        }
        .onKeyPress(.leftArrow) { move(-1, all.count); return .handled }
        .onKeyPress(.rightArrow) { move(1, all.count); return .handled }
        .onKeyPress(.upArrow) { move(-columns, all.count); return .handled }
        .onKeyPress(.downArrow) { move(columns, all.count); return .handled }
        .onKeyPress(.return) { choose(all[focus]); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    @ViewBuilder private func circle(_ choice: String) -> some View {
        if choice == "photo" {
            VStack(spacing: 4) {
                Image(systemName: "photo").font(.system(size: 20))
                Text("Foto dal Mac").font(.system(size: 10.5, weight: .medium)).multilineTextAlignment(.center)
            }
            .foregroundStyle(colors.secondary)
            .frame(width: 84, height: 84)
            .background(colors.fg.opacity(0.1), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1.5))
        } else {
            ProfileAvatar(size: 84, choice: choice)
        }
    }

    private func move(_ step: Int, _ count: Int) {
        let next = focus + step
        guard next >= 0, next < count else { InterfaceSound.blocked.play(); return }
        InterfaceSound.move.play()
        focus = next
    }

    private func choose(_ choice: String) {
        InterfaceSound.select.play()
        if choice == "photo" {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url,
                  let stored = Profile.importPhoto(from: url, replacing: picture) else { return }
            picture = stored
        } else {
            if picture.hasPrefix("photo:") { try? FileManager.default.removeItem(at: Profile.photoURL(String(picture.dropFirst(6)))) }
            picture = choice
        }
        close()
    }
}

private struct GlassCard: ViewModifier {
    @Environment(\.platea) private var colors
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(colors.line))
    }
}

private extension View {
    func glassCard() -> some View { modifier(GlassCard()) }
}
