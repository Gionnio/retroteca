import SwiftUI
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
                case .engines: EnginesPageView()
                case .build(let id): BuildPageView(gameID: id)
                case .options(let id): SwitchOptionsView(gameID: id)
                case .space: SpacePageView()
                case .vetrina: VetrinaView()
                }
            }
            .ignoresSafeArea()
            if !model.viewerOpen { PlateaNavBar().transition(.opacity) }
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

/// Platea client navigation: logo, pills, search, clock, settings.
struct PlateaNavBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
                Text("Retroteca").font(.system(size: 15, weight: .bold))
            }
            .foregroundStyle(colors.fg)
            .padding(.trailing, 10)

            pill("Home", on: model.page == .vetrina) { model.open(.vetrina) }
            pill("Libreria", count: model.games.count, on: model.page == .grid) { model.open(.grid) }
            pill("Motore", on: model.page == .engines) { model.open(.engines) }

            Spacer()
            Button { model.chooseFilesToImport() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).foregroundStyle(colors.secondary)
                .help("Aggiungi giochi")
            if showSearch || !model.searchText.isEmpty {
                TextField(searchPrompt, text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .frame(width: 200)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(colors.line, lineWidth: 1.5))
                    .onSubmit { if model.page == .vetrina { model.open(.grid) } }
                    .onChange(of: model.searchText) { _, text in if !text.isEmpty && model.page == .vetrina { model.open(.grid) } }
            }
            Button {
                showSearch.toggle()
                searchFocused = showSearch
                if !showSearch { model.searchText = "" }
            } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.plain).foregroundStyle(colors.secondary)
            .keyboardShortcut("f")
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .foregroundStyle(colors.secondary).monospacedDigit()
            }
            SettingsLink {
                Image(systemName: "gearshape").frame(width: 30, height: 30).background(colors.card, in: Circle())
            }
            .buttonStyle(.plain).foregroundStyle(colors.fg)
        }
        .font(.system(size: 13))
        .padding(.leading, 84).padding(.trailing, 28)
        .frame(height: 52)
    }

    private var searchPrompt: String {
        String(localized: "Cerca giochi")
    }



    private func pill(_ title: LocalizedStringKey, count: Int? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count { Text("\(count)").font(.system(size: 11)).opacity(0.55).monospacedDigit() }
            }
                .foregroundStyle(colors.fg)
                .opacity(on ? 1 : 0.85)
                .padding(.horizontal, 13).padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(on ? colors.accent : .clear, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
