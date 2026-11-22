import SwiftUI
import AppKit

@main
struct RetrotecaApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("palette") private var palette = PlateaPalette.grafite.rawValue

    /// Settings and About follow the palette: dark for Grafite and Notte blu, light for Giorno.
    private var scheme: ColorScheme { (PlateaPalette(rawValue: palette) ?? .grafite).colors.isDark ? .dark : .light }
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Informazioni su Retroteca") { openWindow(id: "about") }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Impostazioni…") { model.showSettings(.general) }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .sidebar) {
                Button("Menu rapido") { model.toggleQuickMenu() }
                    .keyboardShortcut("k")
            }
            CommandGroup(replacing: .newItem) {
                Button("Aggiungi giochi…") { model.chooseFilesToImport() }
                    .keyboardShortcut("o")
                Button("Ricontrolla i file") { model.refreshFiles() }
                    .keyboardShortcut("r")
            }
        }

        Window("Informazioni su Retroteca", id: "about") {
            AboutView()
                .preferredColorScheme(scheme)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// About window: icon, name, version, credits.
struct AboutView: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 110, height: 110)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            Text("Retroteca").font(.system(size: 26, weight: .bold))
            Text("Versione \(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))")
                .font(.callout).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text("Made with ❤️ by Gionnio").font(.callout)
            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/Gionnio/retroteca")!)
            } label: {
                Text("GitHub Repository")
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
            Text("Retroteca non include giochi, firmware né chiavi: usa i dump dei giochi che possiedi.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Copyright © 2026 Gionnio. Licenza MIT.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 320)
        .background(VisualEffect().ignoresSafeArea())
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
