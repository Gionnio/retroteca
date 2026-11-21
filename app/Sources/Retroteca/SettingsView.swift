import SwiftUI
import RetrotecaCore

struct SettingsView: View {
    var body: some View {
        TabView {
            LibrarySettings().frame(width: 560)
                .tabItem { Label("Libreria", systemImage: "square.grid.2x2") }
            AppearanceSettings().frame(width: 560)
                .tabItem { Label("Aspetto", systemImage: "circle.lefthalf.filled") }
            SpaceSettingsTab().frame(width: 560)
                .tabItem { Label("Spazio", systemImage: "internaldrive") }
            // Wider: the drawn pad needs room for its callouts on both sides.
            ControllerSettings().frame(width: 800)
                .tabItem { Label("Controller", systemImage: "gamecontroller") }
        }
    }
}

private struct LibrarySettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("checkFilesAtLaunch") private var checkFilesAtLaunch = true
    @AppStorage("copyGamesToLibrary") private var copyGamesToLibrary = false
    @AppStorage("downloadArtwork") private var downloadArtwork = true
    @State private var confirmEmpty = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $copyGamesToLibrary) {
                    Text("Copia i giochi importati nella cartella di Retroteca")
                    Text(copyGamesToLibrary
                         ? "I giochi nuovi vanno in Retroteca/Games e occupano il doppio."
                         : "Spento: i giochi restano dove sono.")
                }
            }
            Section {
                Toggle(isOn: $downloadArtwork) {
                    Text("Scarica copertine e schermate")
                    Text("Dal negozio Nintendo.")
                }
            }
            Section {
                Toggle(isOn: $checkFilesAtLaunch) {
                    Text("Controlla i file dei giochi all'avvio")
                    Text("Segnala i giochi con file spostati o cancellati.")
                }
            }
            Section {
                LabeledContent("Cartella di Retroteca") {
                    Button(model.libraryLocation.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        NSWorkspace.shared.open(model.libraryLocation)
                    }
                    .buttonStyle(.link)
                }
            }
            Section {
                LabeledContent("Svuota la libreria") {
                    Button("Svuota…", role: .destructive) { confirmEmpty = true }
                        .disabled(model.games.isEmpty)
                }
            }
        }
        .confirmationDialog(String(localized: "Svuotare la libreria?"), isPresented: $confirmEmpty) {
            Button(String(localized: "Svuota la libreria"), role: .destructive) { model.emptyLibrary() }
        } message: {
            Text("\(model.games.count) giochi escono dalla libreria. I file restano.")
        }
        .formStyle(.grouped)
        .frame(height: 500)
    }
}

/// The choices about disk space; the full picture is the Spazio page in the main window.
private struct SpaceSettingsTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SpaceSettings.modeKey) private var mode = "compact"
    @AppStorage(SpaceSettings.keepFreeKey) private var keepFree = 20

    var body: some View {
        Form {
            Picker(selection: $mode) {
                Text("Veloce").tag("fast")
                Text("Compatto").tag("compact")
            } label: {
                Text("Dopo ogni costruzione")
                Text(mode == "compact" ? "Cache cancellate dopo ogni costruzione." : "Cache tenute: ricostruzioni rapide, da 5 a 30 GB per gioco.")
            }
            .pickerStyle(.segmented)
            Picker(selection: $keepFree) {
                ForEach(SpaceSettings.keepFreeChoices, id: \.self) { Text("\($0) GB").tag($0) }
            } label: {
                Text("Lascia sempre liberi")
                Text("Sotto questa soglia le costruzioni non partono.")
            }
            LabeledContent("Quanto occupa Retroteca") {
                Button("Apri la pagina Spazio") {
                    model.open(.space)
                    NSApp.keyWindow?.close()
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 230)
    }
}

private struct AppearanceSettings: View {
    @AppStorage("palette") private var palette = PlateaPalette.grafite.rawValue

    var body: some View {
        Form {
            Picker(selection: $palette) {
                ForEach(PlateaPalette.allCases) { Text($0.label).tag($0.rawValue) }
            } label: {
                Text("Palette")
                Text("Auto: Giorno dalle 7 alle 19, Notte blu la sera.")
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .frame(height: 150)
    }
}


/// Controller: how Retroteca is driven, the connected pads, and each pad's buttons (saved per pad).
private struct ControllerSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("inputMode") private var inputMode = InputMode.all.rawValue
    @State private var selectedPad: String?

    var body: some View {
        let gamepads = model.gamepads
        Form {
            Section {
                Picker("Comandi di Retroteca", selection: $inputMode) {
                    ForEach(InputMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("Il controller agisce solo con Retroteca in primo piano.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Controller collegati") {
                if gamepads.pads.isEmpty {
                    Text("Nessun controller collegato.")
                        .foregroundStyle(.secondary)
                    PadDrawing(pad: ConnectedPad(id: "preview", name: "Controller", source: .hid, vendorID: nil, productID: nil))
                        .disabled(true).opacity(0.55).padding(.vertical, 6)
                } else {
                    Picker("Controller", selection: Binding(get: { selectedPad ?? gamepads.pads.first?.id }, set: { selectedPad = $0 })) {
                        ForEach(gamepads.pads) { pad in
                            Text("\(pad.name) · \(pad.source == .gameController ? String(localized: "supporto Apple") : String(localized: "HID diretto"))").tag(Optional(pad.id))
                        }
                    }
                    if let pad = gamepads.pads.first(where: { $0.id == (selectedPad ?? gamepads.pads.first?.id) }),
                       pad.source == .hid, [0x057E, 0x045E, 0x054C].contains(pad.vendorID ?? 0) {
                        Label("macOS non riconosce questo controller: nei giochi Switch non funziona. Usane uno elencato in Impostazioni di Sistema › Controller di gioco.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if let last = gamepads.lastPressed {
                        LabeledContent("Ultimo tasto premuto", value: "\(padButtonName(last.button)) · \(last.pad)")
                    } else {
                        LabeledContent("Ultimo tasto premuto", value: String(localized: "premi un tasto per provarlo"))
                    }
                }
            }
            if let pad = gamepads.pads.first(where: { $0.id == (selectedPad ?? gamepads.pads.first?.id) }) {
                let mapping = gamepads.mapping(for: pad)
                Section("Tasti di \(pad.name)") {
                    PadDrawing(pad: pad).padding(.vertical, 8)
                    Text("Clicca un tasto per scegliere cosa fa.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Muoviti", value: String(localized: "croce e levetta sinistra"))
                    ForEach(PadAction.allCases, id: \.self) { action in
                        LabeledContent(padActionName(action)) {
                            HStack {
                                if gamepads.capturing?.padID == pad.id && gamepads.capturing?.action == action {
                                    Text("Premi un tasto sul controller…").foregroundStyle(.orange)
                                    Button("Annulla") { gamepads.capturing = nil }
                                } else {
                                    Text(mapping.buttons[action].map(padButtonName) ?? String(localized: "nessuno")).foregroundStyle(.secondary)
                                    Button("Cambia") { gamepads.capturing = (pad.id, action) }
                                }
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Ripristina predefiniti") { gamepads.resetMapping(for: pad) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
        .onDisappear { gamepads.capturing = nil }
    }
}
