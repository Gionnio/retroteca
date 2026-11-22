import SwiftUI
import RetrotecaCore

private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

/// Colours of the space categories, the same on the page and the game card.
private enum SpaceColor {
    static let apps = Color(white: 0.56)
    static let shaders = Color(hex: 0xC2741F)
    static let otherCaches = Color(hex: 0xE3A857)
    static let leftovers = Color(hex: 0xD63B30)
    static let other = Color(hex: 0x4F7FD9)
}

/// A bar split by category, each part as wide as its share.
private struct StackBar: View {
    @Environment(\.platea) private var colors
    let parts: [(Int64, Color)]
    var height: CGFloat = 14

    var body: some View {
        let total = max(1, parts.reduce(0) { $0 + $1.0 })
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    part.1.frame(width: geo.size.width * CGFloat(part.0) / CGFloat(total))
                }
            }
        }
        .frame(height: height)
        .background(colors.line)
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
    }
}

private struct LegendItem: View {
    @Environment(\.platea) private var colors
    let color: Color
    let title: String
    let value: Int64

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 9, height: 9)
            Text(title).foregroundStyle(colors.fg)
            Spacer(minLength: 8)
            Text(bytes(value)).fontWeight(.semibold).foregroundStyle(colors.fg).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

/// Settings → Spazio: what Retroteca takes (clones counted once), per game, and the choices about caches.
struct SpaceSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    @AppStorage(SpaceSettings.modeKey) private var mode = "compact"
    @AppStorage(SpaceSettings.keepFreeKey) private var keepFree = 20
    @State private var freeing: SpaceManager.Entry?
    @State private var confirmAll = false
    @State private var pickingDisk = false

    var body: some View {
        let space = model.space
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        location(space.report)
                        usage(space.report)
                        perGame(space.report)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 16) {
                        modeCard
                        marginCard
                        allCard(space.report)
                    }
                    .frame(width: 330)
                }
        .task { model.space.measure(games: model.games) }
        // A disk plugged in or ejected while the page is open: its card and free space follow.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in model.space.measure(games: model.games) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in model.space.measure(games: model.games) }
        .sheet(item: $freeing) { entry in
            FreeSpaceSheet(entry: entry, game: entry.gameID.flatMap(model.game(id:))) { freeing = nil }
                .environment(\.platea, colors).environmentObject(model)
        }
        .sheet(isPresented: $pickingDisk) {
            DiskPicker { pickingDisk = false }
                .environment(\.platea, colors).environmentObject(model)
        }
        .confirmationDialog(String(localized: "Liberare le cache di tutti i giochi?"), isPresented: $confirmAll) {
            Button(String(localized: "Libera \(bytes(space.report?.freeable ?? 0))"), role: .destructive) {
                for entry in space.report?.entries ?? [] where entry.space.freeable > 0 && !isBuilding(entry) {
                    space.freeCaches(titleID: entry.id, title: entry.title, games: model.games)
                }
            }
        } message: {
            Text("La prossima costruzione di ogni gioco ripartirà da capo.")
        }
    }

    private func isBuilding(_ entry: SpaceManager.Entry) -> Bool {
        entry.gameID != nil && entry.gameID == model.switchGames.buildingID
    }

    /// Where games are built and kept: this Mac or a disk; and moving the apps already built on the Mac.
    @ViewBuilder private func location(_ report: SpaceManager.Report?) -> some View {
        let disk = GamesLocation.volume
        let connected = GamesLocation.isAvailable
        OptionCard(title: String(localized: "DOVE VANNO I GIOCHI"),
                   trailing: disk.map { connected ? String(localized: "\($0.lastPathComponent) collegato") : String(localized: "\($0.lastPathComponent) non collegato") }) {
            diskRow(icon: "laptopcomputer", title: String(localized: "Questo Mac"),
                    detail: "~/Applications/Retroteca", on: disk == nil) { model.chooseGamesVolume(nil) }
            if let disk {
                let free = report?.volumes.first { $0.url.path == disk.path }?.free
                diskRow(icon: "externaldrive", title: disk.lastPathComponent,
                        detail: connected ? free.map { String(localized: "\(bytes($0)) liberi · Retroteca") } ?? "Retroteca" : String(localized: "non collegato"),
                        on: true) {}
            }
            HStack(spacing: 10) {
                Button(String(localized: "Scegli un disco…")) { pickingDisk = true }
                    .buttonStyle(PlateaButtonStyle()).controlSize(.small)
                    .disabled(model.buildingGameID != nil || model.moving != nil)
                Text("I salvataggi restano sempre sul Mac.").font(.system(size: 12)).foregroundStyle(colors.secondary)
            }
            .padding(.top, 4)
            if let moving = model.moving {
                HStack(spacing: 10) {
                    ProgressView(value: Double(moving.done), total: Double(max(moving.total, 1))).frame(width: 140)
                    Text("Copio \(moving.title) · \(moving.done + 1) di \(moving.total)").font(.system(size: 12)).foregroundStyle(colors.fg)
                    Spacer()
                    Button(String(localized: "Interrompi")) { model.stopMoving() }.buttonStyle(PlateaButtonStyle(destructive: true)).controlSize(.small)
                }
                .padding(.top, 8)
            } else if disk != nil, connected, !model.appsOnMac.isEmpty {
                let count = model.appsOnMac.count
                HStack(spacing: 10) {
                    Button(count == 1 ? String(localized: "Sposta 1 gioco sul disco") : String(localized: "Sposta \(count) giochi sul disco")) { model.moveAppsToDisk() }
                        .buttonStyle(PlateaButtonStyle(primary: true)).controlSize(.small)
                        .disabled(model.buildingGameID != nil || model.runningGameID != nil)
                    Text("Ancora sul Mac.").font(.system(size: 12)).foregroundStyle(colors.secondary)
                }
                .padding(.top, 8)
            }
        }
    }

    private func diskRow(icon: String, title: String, detail: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17)).foregroundStyle(colors.fg).frame(width: 34, height: 34)
                    .background(colors.line, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(colors.fg)
                    Text(detail).font(.system(size: 12)).foregroundStyle(colors.secondary)
                }
                Spacer()
                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? colors.accent : colors.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(on ? colors.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? colors.accent : colors.line, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(model.buildingGameID != nil || model.moving != nil)
        .padding(.bottom, 6)
    }

    @ViewBuilder private func usage(_ report: SpaceManager.Report?) -> some View {
        OptionCard(title: String(localized: "OCCUPATO DA RETROTECA"),
                   trailing: report.map { String(localized: "Disco: \(bytes($0.freeDisk)) liberi su \(bytes($0.capacity))") }) {
            if let report {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bytes(report.total)).font(.system(size: 26, weight: .bold)).foregroundStyle(colors.fg)
                    if report.finderTotal > report.total + (1 << 30) {
                        Text("reali · il Finder ne conta \(bytes(report.finderTotal))")
                            .font(.system(size: 12)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                StackBar(parts: [(report.apps, SpaceColor.apps), (report.shaders, SpaceColor.shaders), (report.otherCaches, SpaceColor.otherCaches),
                                 (report.other.allocated, SpaceColor.other), (report.leftovers, SpaceColor.leftovers)])
                    .padding(.vertical, 10)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    LegendItem(color: SpaceColor.apps, title: String(localized: "App dei giochi"), value: report.apps)
                    LegendItem(color: SpaceColor.shaders, title: String(localized: "Cache degli shader"), value: report.shaders)
                    LegendItem(color: SpaceColor.otherCaches, title: String(localized: "Altre cache di costruzione"), value: report.otherCaches)
                    LegendItem(color: SpaceColor.other, title: String(localized: "Motore, copertine e strumenti"), value: report.other.allocated)
                    LegendItem(color: SpaceColor.leftovers, title: String(localized: "Resti di versioni vecchie del motore"), value: report.leftovers)
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Misuro…").foregroundStyle(colors.secondary) }
                    .font(.system(size: 13)).padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder private func perGame(_ report: SpaceManager.Report?) -> some View {
        if let report, !report.entries.isEmpty {
            OptionCard(title: String(localized: "PER GIOCO"), trailing: model.space.isMeasuring ? String(localized: "Misuro…") : nil) {
                ForEach(report.entries) { entry in
                    let game = entry.gameID.flatMap(model.game(id:))
                    OptionRow(title: entry.title, note: note(entry, game: game)) {
                        HStack(spacing: 14) {
                            StackBar(parts: [(entry.space.app.allocated, SpaceColor.apps), (entry.space.shaders.own, SpaceColor.shaders),
                                             (entry.space.otherCaches.own, SpaceColor.otherCaches), (entry.space.leftovers.own, SpaceColor.leftovers)], height: 6)
                                .frame(width: 110)
                            Text(bytes(entry.space.total)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(colors.fg)
                                .monospacedDigit().frame(width: 72, alignment: .trailing)
                            freeButton(entry)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func freeButton(_ entry: SpaceManager.Entry) -> some View {
        let space = model.space
        Group {
            if space.freeing.contains(entry.id) {
                ProgressView().controlSize(.small)
            } else if isBuilding(entry) {
                Text("In costruzione").font(.system(size: 12)).foregroundStyle(colors.secondary)
            } else if entry.space.freeable < (64 << 20) {
                Text("—").foregroundStyle(colors.secondary)
            } else if entry.gameID == nil {
                Button(String(localized: "Togli i resti")) { space.freeCaches(titleID: entry.id, title: entry.title, games: model.games) }
                    .buttonStyle(PlateaButtonStyle()).controlSize(.small)
            } else {
                Button(String(localized: "Libera \(bytes(entry.space.freeable))")) { freeing = entry }
                    .buttonStyle(PlateaButtonStyle()).controlSize(.small)
            }
        }
        .frame(width: 130, alignment: .trailing)
    }

    private func note(_ entry: SpaceManager.Entry, game: Game?) -> String {
        guard let game else { return String(localized: "Non più in libreria") }
        if game.nativeApp == nil { return String(localized: "Da costruire") }
        if entry.space.caches < (64 << 20) { return String(localized: "Cache liberate") }
        return String(localized: "Cache \(bytes(entry.space.caches))")
    }

    private var modeCard: some View {
        OptionCard(title: String(localized: "DOPO OGNI COSTRUZIONE")) {
            VStack(spacing: 10) {
                choice("fast", String(localized: "Veloce"),
                       String(localized: "Tiene le cache: ricostruire richiede pochi minuti. Da 5 a 30 GB in più per gioco."))
                choice("compact", String(localized: "Compatto"),
                       String(localized: "Cancella le cache quando l'app è pronta. Ricostruire richiede più tempo."))
            }
        }
    }

    private func choice(_ value: String, _ title: String, _ text: String) -> some View {
        let on = mode == value
        return Button { mode = value } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? colors.accent : colors.secondary)
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(colors.fg)
                }
                Text(text).font(.system(size: 12)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? colors.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? colors.accent : colors.line, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var marginCard: some View {
        OptionCard(title: String(localized: "SPAZIO PER COSTRUIRE")) {
            OptionRow(title: String(localized: "Lascia sempre liberi"),
                      note: String(localized: "Sotto questa soglia le costruzioni non partono.")) {
                Picker("", selection: $keepFree) {
                    ForEach(SpaceSettings.keepFreeChoices, id: \.self) { Text("\($0) GB").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    @ViewBuilder private func allCard(_ report: SpaceManager.Report?) -> some View {
        OptionCard(title: String(localized: "TUTTO INSIEME")) {
            Button(String(localized: "Libera le cache di tutti i giochi · \(bytes(report?.freeable ?? 0))")) { confirmAll = true }
                .buttonStyle(PlateaButtonStyle(destructive: true))
                .disabled((report?.freeable ?? 0) < (64 << 20))
            Text("I giochi restano giocabili.")
                .font(.system(size: 11.5)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
    }
}

/// "SPAZIO" on a built Switch game's page: the app and the build caches, and freeing them.
struct GameSpaceCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game
    @State private var freeing: SpaceManager.Entry?

    var body: some View {
        let space = model.space
        let entry = space.entry(titleID: game.titleID)
        OptionCard(title: String(localized: "SPAZIO"), trailing: entry.map { bytes($0.space.total) }) {
            if let entry {
                let s = entry.space
                StackBar(parts: [(s.app.allocated, SpaceColor.apps), (s.shaders.own, SpaceColor.shaders),
                                 (s.otherCaches.own, SpaceColor.otherCaches), (s.leftovers.own, SpaceColor.leftovers)])
                    .padding(.bottom, 6)
                row(String(localized: "App del gioco"), s.app.allocated, nil)
                if s.shaders.own > 0 { row(String(localized: "Cache degli shader"), s.shaders.own, nil) }
                if s.otherCaches.own > 0 { row(String(localized: "Altre cache di costruzione"), s.otherCaches.own, nil) }
                if s.leftovers.own > 0 { row(String(localized: "Resti di versioni vecchie del motore"), s.leftovers.own, nil) }
                HStack(spacing: 12) {
                    if space.freeing.contains(entry.id) {
                        ProgressView().controlSize(.small)
                    } else if s.freeable >= (64 << 20) {
                        Button(String(localized: "Libera \(bytes(s.freeable))")) { freeing = entry }
                            .buttonStyle(PlateaButtonStyle())
                            .disabled(model.switchGames.buildingID == game.id)
                    }
                    Text(s.freeable < (64 << 20) ? String(localized: "Nessuna cache.")
                                                 : String(localized: "Il gioco resta giocabile."))
                        .font(.system(size: 12)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(String(localized: "Tutto lo spazio")) { model.open(.settings(.space)) }.buttonStyle(.link).font(.system(size: 12))
                }
                .padding(.top, 8)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Misuro…").foregroundStyle(colors.secondary) }.font(.system(size: 13))
            }
        }
        .task(id: game.nativeApp) { model.space.measure(games: model.games) }
        .sheet(item: $freeing) { entry in
            FreeSpaceSheet(entry: entry, game: game) { freeing = nil }
                .environment(\.platea, colors).environmentObject(model)
        }
    }

    private func row(_ title: String, _ value: Int64, _ note: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).foregroundStyle(colors.secondary).frame(width: 190, alignment: .leading)
            Text(bytes(value)).foregroundStyle(colors.fg).monospacedDigit()
            if let note { Text("· \(note)").foregroundStyle(colors.secondary) }
        }
        .font(.system(size: 12.5)).padding(.vertical, 1)
    }
}

/// What to free for one game: the caches (checked), the app itself (not checked). Saves and the user's files are never touched.
struct FreeSpaceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let entry: SpaceManager.Entry
    let game: Game?
    let close: () -> Void
    @State private var shaders = true
    @State private var others = true
    @State private var app = false

    var body: some View {
        let s = entry.space
        let total = (shaders ? s.shaders.own : 0) + (others ? s.otherCaches.own : 0) + s.leftovers.own + (app ? s.app.allocated : 0)
        VStack(alignment: .leading, spacing: 10) {
            Text("Liberare \(bytes(total)) di \(entry.title)?").font(.system(size: 17, weight: .bold)).foregroundStyle(colors.fg)
            Text("Salvataggi e file del gioco restano.")
                .font(.system(size: 13)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
            if s.shaders.own > 0 {
                check($shaders, String(localized: "Cache degli shader · \(bytes(s.shaders.own))"),
                      String(localized: "Ricostruirle può richiedere ore."))
            }
            if s.otherCaches.own > 0 {
                check($others, String(localized: "Altre cache di costruzione · \(bytes(s.otherCaches.own))"),
                      String(localized: "Pipeline ed estrazione."))
            }
            if s.leftovers.own > 0 {
                Text("Più \(bytes(s.leftovers.own)) di resti del motore.")
                    .font(.system(size: 12)).foregroundStyle(colors.secondary)
            }
            if let game, game.nativeApp != nil, s.app.allocated > 0 {
                check($app, String(localized: "Anche l'app del gioco · \(bytes(s.app.allocated))"),
                      String(localized: "Andrà ricostruita per giocare."))
            }
            HStack(spacing: 10) {
                Spacer()
                Button(String(localized: "Annulla")) { close() }.buttonStyle(PlateaButtonStyle()).keyboardShortcut(.cancelAction)
                Button(String(localized: "Libera \(bytes(total))")) {
                    model.space.freeCaches(titleID: entry.id, title: entry.title, games: model.games, shaders: shaders, others: others)
                    if app, let game { model.deleteNativeApp(game.id) }
                    close()
                }
                .buttonStyle(PlateaButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                .disabled(total == 0)
            }
            .padding(.top, 8)
        }
        .padding(22)
        .frame(width: 470)
        .background(colors.bg)
    }

    private func check(_ value: Binding<Bool>, _ title: String, _ note: String) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(colors.fg)
                Text(note).font(.system(size: 12)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// The disks attached to the Mac: the suitable ones to pick, the others with the reason.
struct DiskPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let close: () -> Void
    /// Read when the sheet opens and again whenever a disk is plugged in or ejected.
    @State private var volumes = GamesVolume.mounted()
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dove costruire e tenere i giochi?").font(.system(size: 17, weight: .bold)).foregroundStyle(colors.fg)
            Text("I giochi vanno nella cartella Retroteca del disco.")
                .font(.system(size: 13)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
            if volumes.isEmpty {
                Text("Nessun disco esterno collegato.").font(.system(size: 13)).foregroundStyle(colors.fg).padding(.vertical, 8)
            }
            ForEach(volumes) { volume in
                let ok = volume.verdict == .suitable
                Button { if ok { selected = volume.id } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: volume.isLocal ? "externaldrive" : "server.rack").font(.system(size: 17)).frame(width: 34, height: 34)
                            .background(colors.line, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(colors.fg)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volume.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(colors.fg)
                            switch volume.verdict {
                            case .suitable:
                                Text("\(volume.format.uppercased()) · \(ByteCountFormatter.string(fromByteCount: volume.free, countStyle: .file)) liberi")
                                    .font(.system(size: 12)).foregroundStyle(colors.secondary)
                            case .unsuitable(let problem):
                                Text(Self.text(problem)).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        if ok { Image(systemName: selected == volume.id ? "largecircle.fill.circle" : "circle").foregroundStyle(selected == volume.id ? colors.accent : colors.secondary) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected == volume.id ? colors.accent : colors.line, lineWidth: 1.5))
                    .opacity(ok ? 1 : 0.6)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Spacer()
                Button(String(localized: "Annulla")) { close() }.buttonStyle(PlateaButtonStyle()).keyboardShortcut(.cancelAction)
                Button(String(localized: "Usa questo disco")) {
                    if let volume = volumes.first(where: { $0.id == selected }) { model.chooseGamesVolume(volume.url) }
                    close()
                }
                .buttonStyle(PlateaButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
            .padding(.top, 8)
        }
        .padding(22)
        .frame(width: 500)
        .background(colors.bg)
        .onAppear { volumes = GamesVolume.mounted(); selected = GamesLocation.volume?.path }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in reload() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in reload() }
    }

    private func reload() {
        volumes = GamesVolume.mounted()
        if let id = selected, !volumes.contains(where: { $0.id == id }) { selected = nil }
    }

    static func text(_ problem: GamesVolume.Problem) -> String {
        switch problem {
        case .network: return String(localized: "Disco di rete: lento per costruire e per giocare.")
        case .readOnly: return String(localized: "Disco in sola lettura.")
        case .macOSExtended: return String(localized: "Mac OS Esteso: serve APFS (Utility Disco).")
        case .fat: return String(localized: "exFAT o FAT: serve APFS.")
        case .format(let name): return String(localized: "Formato \(name): serve APFS.")
        }
    }
}
