import SwiftUI
import RetrotecaCore

/// "Ready" in the top corner when a build ends well: the game's icon, its name, and Play.
struct ReadyNotice: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors

    var body: some View {
        if let id = model.readyNotice, let game = model.game(id: id) {
            HStack(spacing: 12) {
                GameArt(game: game, wide: false).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.fg).lineLimit(1)
                    Text("È pronto").font(.system(size: 11.5)).foregroundStyle(colors.secondary)
                }
                Spacer(minLength: 8)
                Button { model.play(game) } label: { Label("Gioca", systemImage: "play.fill") }
                    .buttonStyle(PlateaButtonStyle(primary: true)).controlSize(.small)
            }
            .padding(12)
            .frame(width: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(colors.line))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
            .padding(.top, 60).padding(.trailing, 28)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// The quick menu (pad's Menu button or ⌘K): the build running, then shortcuts. Left / right move, A chooses, B closes.
struct QuickMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    @AppStorage("palette") private var palette = PlateaPalette.grafite.rawValue

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { model.toggleQuickMenu() }
            VStack(alignment: .leading, spacing: 14) {
                if let id = model.switchGames.buildingID, let game = model.game(id: id) {
                    let fraction = model.switchGames.builds[id]?.overallFraction ?? 0
                    HStack(spacing: 12) {
                        GameArt(game: game).frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(game.title) · costruzione \(Int(fraction * 100))%").font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.fg)
                            ProgressView(value: fraction).tint(colors.accent)
                        }
                        Button(String(localized: "Segui")) { model.toggleQuickMenu(); model.open(.builds) }.buttonStyle(PlateaButtonStyle()).controlSize(.small)
                        Button { model.pauseBuild(game) } label: { Image(systemName: "pause.fill") }.buttonStyle(PlateaButtonStyle()).controlSize(.small)
                    }
                }
                HStack(spacing: 10) {
                    ForEach(Array(AppModel.QuickAction.allCases.enumerated()), id: \.offset) { index, action in
                        tile(action, focused: index == model.quickFocus) { model.quickFocus = index; model.runQuick(action) }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 760)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(colors.line))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
            .padding(.bottom, 44)
        }
        .transition(.opacity)
    }

    private func tile(_ action: AppModel.QuickAction, focused: Bool, run: @escaping () -> Void) -> some View {
        let (symbol, title, detail) = describe(action)
        return Button(action: run) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol).font(.system(size: 18))
                Spacer()
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(colors.secondary).lineLimit(1)
            }
            .foregroundStyle(colors.fg)
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 84, alignment: .leading)
            .background(colors.fg.opacity(focused ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? colors.fg : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func describe(_ action: AppModel.QuickAction) -> (String, String, String) {
        switch action {
        case .sounds: return ("speaker.wave.2", String(localized: "Suoni"), InterfaceSound.isEnabled ? String(localized: "accesi") : String(localized: "spenti"))
        case .palette: return ("circle.lefthalf.filled", String(localized: "Aspetto"), (PlateaPalette(rawValue: palette) ?? .grafite).name)
        case .space: return ("internaldrive", String(localized: "Spazio"), ByteCountFormatter.string(fromByteCount: model.switchGames.freeSpace, countStyle: .file))
        case .settings: return ("gearshape", String(localized: "Impostazioni"), String(localized: "motore, pad"))
        case .fullScreen: return ("arrow.up.left.and.arrow.down.right", String(localized: "Schermo intero"), "")
        case .quit: return ("power", String(localized: "Esci"), String(localized: "chiudi Retroteca"))
        }
    }
}

/// After a few idle minutes: the games' art drifting slowly across the screen, with the time. Any input ends it.
struct Screensaver: View {
    @EnvironmentObject var model: AppModel
    @State private var index = 0
    @State private var zoom = false

    var body: some View {
        let games = model.games.filter { $0.backdropURL != nil }
        ZStack(alignment: .bottomTrailing) {
            Color.black.ignoresSafeArea()
            if !games.isEmpty {
                let game = games[index % games.count]
                GameArt(game: game, backdrop: true)
                    .scaleEffect(zoom ? 1.14 : 1.04)
                    .id(game.id)
                    .transition(.opacity)
                    .ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .bottomTrailing, endPoint: .center).ignoresSafeArea()
                VStack(alignment: .trailing, spacing: 2) {
                    TimelineView(.everyMinute) { context in
                        Text(context.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 54, weight: .thin)).monospacedDigit()
                    }
                    Text(game.title).font(.system(size: 14)).opacity(0.75)
                }
                .foregroundStyle(.white)
                .padding(48)
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 12)) { zoom = true } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                withAnimation(.easeInOut(duration: 1.2)) { index += 1 }
                zoom = false
                withAnimation(.easeInOut(duration: 12)) { zoom = true }
            }
        }
        .onTapGesture { model.noteInput() }
        .transition(.opacity)
    }
}
