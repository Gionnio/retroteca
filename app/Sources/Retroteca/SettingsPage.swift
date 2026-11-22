import SwiftUI
import RetrotecaCore

/// The sections of the full-window settings, opened from the gear in the top bar (or ⌘,).
enum SettingsSection: String, CaseIterable, Hashable {
    case general, engine, space, controller

    var title: String {
        switch self {
        case .general: return String(localized: "Generale")
        case .engine: return String(localized: "Motore")
        case .space: return String(localized: "Spazio")
        case .controller: return String(localized: "Pad")
        }
    }
}

/// Settings as a page of the app, in its style: title, section pills, the section's cards. L and R change section.
struct SettingsPageView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let section: SettingsSection

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                BackButton()
                Text("Impostazioni").font(.system(size: 34, weight: .bold)).foregroundStyle(colors.fg)
                HStack(spacing: 8) {
                    ForEach(SettingsSection.allCases, id: \.self) { item in
                        PillButton(title: item.title, isOn: item == section) { model.showSettings(item) }
                    }
                }
                .padding(.top, 14).padding(.bottom, 20)
                Group {
                    switch section {
                    case .general: GeneralSection()
                    case .engine: SwitchEngineCard().frame(maxWidth: 680, alignment: .leading)
                    case .space: SpaceSection()
                    case .controller:
                        ControllerSettings()
                            .frame(maxWidth: 820, alignment: .leading)
                            .background(colors.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 48).padding(.top, 52 + 30).padding(.bottom, 40)
        }
        .fadesUnderTopBar()
        .onReceive(model.navigation) { command in
            let all = SettingsSection.allCases
            guard let index = all.firstIndex(of: section) else { return }
            if command == .previousSection, index > 0 { model.showSettings(all[index - 1]) }
            if command == .nextSection, index < all.count - 1 { model.showSettings(all[index + 1]) }
        }
    }
}

/// Look, language, sounds and library, as cards.
private struct GeneralSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    @AppStorage("palette") private var palette = PlateaPalette.grafite.rawValue
    @AppStorage(InterfaceSound.settingKey) private var sounds = true
    @AppStorage("screensaver") private var screensaver = true
    @AppStorage("checkFilesAtLaunch") private var checkFilesAtLaunch = true
    @AppStorage("copyGamesToLibrary") private var copyGamesToLibrary = false
    @AppStorage("downloadArtwork") private var downloadArtwork = true
    @State private var language = AppLanguage.current
    @State private var languageChanged = false
    @State private var confirmEmpty = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            OptionCard(title: String(localized: "ASPETTO")) {
                OptionRow(title: String(localized: "Palette"), note: String(localized: "Auto: Giorno dalle 7 alle 19, Notte blu la sera.")) {
                    Segments(options: PlateaPalette.allCases.map { ($0.rawValue, $0.name) }, selection: palette) { palette = $0 }
                }
                OptionRow(title: String(localized: "Lingua"), note: languageChanged ? String(localized: "La lingua cambia al prossimo avvio.") : nil) {
                    HStack(spacing: 8) {
                        Segments(options: [(AppLanguage.system.rawValue, String(localized: "Sistema")),
                                           (AppLanguage.italian.rawValue, "Italiano"), (AppLanguage.english.rawValue, "English")],
                                 selection: language.rawValue) { value in
                            language = AppLanguage(rawValue: value) ?? .system
                            AppLanguage.set(language)
                            languageChanged = true
                        }
                        if languageChanged { Button(String(localized: "Riavvia ora")) { AppLanguage.relaunch() }.buttonStyle(PlateaButtonStyle()).controlSize(.small) }
                    }
                }
                OptionRow(title: String(localized: "Suoni dell'interfaccia")) {
                    Toggle("", isOn: $sounds).labelsHidden().toggleStyle(.switch)
                        .onChange(of: sounds) { _, on in if on { InterfaceSound.select.play() } }
                }
                OptionRow(title: String(localized: "Salvaschermo"), note: String(localized: "Dopo 5 minuti senza tocchi.")) {
                    Toggle("", isOn: $screensaver).labelsHidden().toggleStyle(.switch)
                }
            }
            OptionCard(title: String(localized: "LIBRERIA")) {
                OptionRow(title: String(localized: "Copia i giochi importati nella cartella di Retroteca"),
                          note: copyGamesToLibrary ? String(localized: "I giochi nuovi vanno in Retroteca/Games e occupano il doppio.") : String(localized: "Spento: i giochi restano dove sono.")) {
                    Toggle("", isOn: $copyGamesToLibrary).labelsHidden().toggleStyle(.switch)
                }
                OptionRow(title: String(localized: "Scarica copertine e schermate"), note: String(localized: "Dal negozio Nintendo.")) {
                    Toggle("", isOn: $downloadArtwork).labelsHidden().toggleStyle(.switch)
                }
                OptionRow(title: String(localized: "Controlla i file dei giochi all'avvio"), note: String(localized: "Segnala i giochi con file spostati o cancellati.")) {
                    Toggle("", isOn: $checkFilesAtLaunch).labelsHidden().toggleStyle(.switch)
                }
                OptionRow(title: String(localized: "Cartella di Retroteca")) {
                    Button(model.libraryLocation.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) { NSWorkspace.shared.open(model.libraryLocation) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
                OptionRow(title: String(localized: "Svuota la libreria")) {
                    Button(String(localized: "Svuota…")) { confirmEmpty = true }.buttonStyle(PlateaButtonStyle(destructive: true)).controlSize(.small)
                        .disabled(model.games.isEmpty)
                }
            }
        }
        .confirmationDialog(String(localized: "Svuotare la libreria?"), isPresented: $confirmEmpty) {
            Button(String(localized: "Svuota la libreria"), role: .destructive) { model.emptyLibrary() }
        } message: {
            Text("\(model.games.count) giochi escono dalla libreria. I file restano.")
        }
    }
}
