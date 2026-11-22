import SwiftUI
import GameController
import UniformTypeIdentifiers
import RetrotecaCore

/// The window: Platea-style pages in the palette chosen in Settings.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("palette") private var palette = PlateaPalette.grafite.rawValue

    var body: some View { content }

    @ViewBuilder private var content: some View {
        let colors = (PlateaPalette(rawValue: palette) ?? .grafite).colors
        PlateaShell()
            .environment(\.platea, colors)
            .preferredColorScheme(colors.isDark ? .dark : .light)
    }
}

/// Full-window pages under a transparent title bar, with the pill navigation on top.
struct PlateaShell: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    @State private var isDropTargeted = false

    var body: some View {
        ZStack(alignment: .top) {
            colors.bg.ignoresSafeArea()
            Group {
                switch model.page {
                case .grid: LibraryGridView()
                case .game(let id): GamePageView(gameID: id)
                case .builds: BuildsPageView()
                case .build(let id): BuildPageView(gameID: id)
                case .options(let id): SwitchOptionsView(gameID: id)
                case .settings(let section): SettingsPageView(section: section)
                case .vetrina: VetrinaView()
                }
            }
            .ignoresSafeArea()
            if !model.viewerOpen { PlateaNavBar().transition(.opacity) }
            if !model.viewerOpen, !model.gamepads.pads.isEmpty { HintsBar().frame(maxHeight: .infinity, alignment: .bottom) }
            ToastOverlay()
            if let id = model.launchingGameID, let game = model.game(id: id) {
                LaunchOverlay(game: game).zIndex(10)
            }
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(colors.accent, lineWidth: 3)
                    .background(colors.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .overlay { Text("Rilascia per aggiungere i giochi").font(.title2.weight(.semibold)).foregroundStyle(colors.fg) }
                    .padding(20)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 1000, minHeight: 620)
        .modifier(TransparentTitleBar())
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            model.importDropped(providers)
            return true
        }
    }
}

/// macOS 15+: no title and no toolbar background, so the page runs under the traffic lights.
struct TransparentTitleBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// The top bar of the Gioco branch: name and sections on one line; on the right the build running, free space,
/// the pad, the settings gear, the clock and the user.
struct PlateaNavBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors

    var body: some View {
        HStack(spacing: 22) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
                Text("Retroteca").font(.system(size: 15, weight: .bold))
            }
            .foregroundStyle(colors.fg)
            section("Giochi", page: .vetrina)
            section("Libreria", page: .grid)
            section("Costruzioni", page: .builds)
            Spacer()
            if let id = model.switchGames.buildingID {
                let fraction = model.switchGames.builds[id]?.overallFraction ?? 0
                Button { model.open(.builds) } label: {
                    ZStack {
                        Circle().stroke(colors.fg.opacity(0.18), lineWidth: 3)
                        Circle().trim(from: 0, to: max(0.02, fraction)).stroke(colors.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                    }
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain).help(String(localized: "Costruzione \(Int(fraction * 100))%"))
            }
            TimelineView(.everyMinute) { context in
                HStack(spacing: 18) {
                    if !GamesLocation.isAvailable, let disk = GamesLocation.volume?.lastPathComponent {
                        Label(String(localized: "\(disk) non collegato"), systemImage: "externaldrive.badge.xmark")
                    } else {
                        Text("Spazio \(ByteCountFormatter.string(fromByteCount: model.switchGames.freeSpace, countStyle: .file))")
                    }
                    if let pad = PadStatus.current {
                        HStack(spacing: 5) {
                            Image(systemName: "gamecontroller.fill")
                            if let level = pad.battery { Text("\(Int(level * 100))%").monospacedDigit() }
                        }
                        .help(pad.name)
                    }
                }
                .foregroundStyle(colors.secondary)
                .id(context.date)
            }
            Button { model.showSettings(.general) } label: {
                Image(systemName: "gearshape").frame(width: 30, height: 30).background(colors.card, in: Circle())
            }
            .buttonStyle(.plain).foregroundStyle(colors.fg).help(String(localized: "Impostazioni"))
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened)).foregroundStyle(colors.secondary).monospacedDigit()
            }
            Text(String(NSFullUserName().prefix(1)).uppercased())
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(LinearGradient(colors: [colors.accent, colors.accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5))
        }
        .font(.system(size: 13))
        .padding(.leading, 84).padding(.trailing, 28)
        .frame(height: 52)
    }

    private func isOn(_ page: Page) -> Bool {
        switch (page, model.page) {
        case (.vetrina, .vetrina), (.grid, .grid), (.builds, .builds): return true
        case (.builds, .build): return true
        default: return false
        }
    }

    /// A section name with a line under it when on screen; the line does not move the text.
    private func section(_ title: LocalizedStringKey, page: Page) -> some View {
        let on = isOn(page)
        return Button { model.open(page) } label: {
            Text(title)
                .font(.system(size: 14, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? colors.fg : colors.secondary)
                .overlay(alignment: .bottom) {
                    Capsule().fill(colors.fg).frame(height: 2).offset(y: 6).opacity(on ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The first controller macOS lists, with its battery when it reports one.
struct PadStatus {
    let name: String
    let battery: Float?

    static var current: PadStatus? {
        guard let controller = GCController.controllers().first else { return nil }
        let level = controller.battery.map(\.batteryLevel).flatMap { $0 > 0 ? $0 : nil }
        return PadStatus(name: controller.vendorName ?? String(localized: "Pad"), battery: level)
    }
}

/// The pad's buttons for the page on screen, along the bottom edge, while a controller is connected.
struct HintsBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors

    var body: some View {
        HStack(spacing: 22) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 6) {
                    Text(hint.0).font(.system(size: 10, weight: .heavy)).foregroundStyle(colors.fg)
                        .frame(minWidth: 18, minHeight: 18).padding(.horizontal, hint.0.count > 1 ? 4 : 0)
                        .overlay(RoundedRectangle(cornerRadius: hint.0.count > 1 ? 4 : 9).strokeBorder(colors.secondary, lineWidth: 1.5))
                    Text(hint.1).font(.system(size: 11.5)).foregroundStyle(colors.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 48).padding(.vertical, 12)
        .allowsHitTesting(false)
    }

    private var hints: [(String, String)] {
        switch model.page {
        case .vetrina: return [("A", String(localized: "Gioca")), ("Y", String(localized: "Scheda")), ("L R", String(localized: "Sezioni"))]
        case .grid: return [("A", String(localized: "Apri")), ("L R", String(localized: "Sezioni"))]
        case .builds: return [("B", String(localized: "Indietro")), ("L R", String(localized: "Sezioni"))]
        case .settings: return [("B", String(localized: "Indietro")), ("L R", String(localized: "Sezioni"))]
        default: return [("A", String(localized: "Scegli")), ("B", String(localized: "Indietro"))]
        }
    }
}
