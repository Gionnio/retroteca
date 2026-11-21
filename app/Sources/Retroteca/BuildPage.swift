import SwiftUI
import RetrotecaCore

/// A Switch game's build, as a Platea page: the game's art, label, title, chips with the stage and progress,
/// then the FASI and REGISTRO cards. The build keeps going when the page is left.
struct BuildPageView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let gameID: UUID
    @State private var showsLog = false

    var body: some View {
        if let game = model.game(id: gameID) {
            let info = model.buildInfo(for: game)
            let state = info.state
            let building = info.building
            let done = game.nativeApp != nil && !building
            ZStack(alignment: .topLeading) {
                GameArt(game: game, backdrop: true).ignoresSafeArea()
                BackdropShade().ignoresSafeArea()
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        BackButton()
                        Kicker(text: String(localized: "COSTRUZIONE · \(model.platformName(game.platformID).uppercased())"))
                        Text(game.title)
                            .font(.system(size: 40, weight: .bold)).tracking(-0.6).foregroundStyle(colors.fg)
                            .lineLimit(2).minimumScaleFactor(0.7).padding(.top, 8).padding(.bottom, 10)
                        Text(meta(game, state: state)).font(.system(size: 13)).foregroundStyle(colors.fg.opacity(0.9))
                        chips(state, building: building, done: done).padding(.vertical, 10)
                        if building {
                            ProgressView(value: state.overallFraction).progressViewStyle(.linear).tint(colors.accent).frame(maxWidth: 420)
                        }
                        actions(game, building: building, done: done).padding(.top, 14)
                        stagesCard(state, game: game, building: building, done: done).padding(.top, 18)
                        logCard(state, game: game).padding(.top, 14)
                        Spacer(minLength: 40)
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 48)
                    .padding(.top, 52 + 24)
                }
                .fadesUnderTopBar()
            }
        } else {
            Color.clear.onAppear { model.back() }
        }
    }

    private func meta(_ game: Game, state: NXBuildState) -> String {
        var parts: [String] = []
        let info = model.buildInfo(for: game)
        if let engine = info.engine { parts.append(String(localized: "motore \(engine)")) }
        if let version = state.version { parts.append(String(localized: "versione \(version)")) }
        if let started = info.started { parts.append(String(localized: "iniziata alle \(started.formatted(date: .omitted, time: .shortened))")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func chips(_ state: NXBuildState, building: Bool, done: Bool) -> some View {
        HStack(spacing: 6) {
            if done {
                PlateaChip(text: "✓ " + String(localized: "App Mac pronta"), tint: colors.ok)
            } else if building {
                PlateaChip(text: String(localized: "Fase \(state.current ?? 0) di \(max(state.stageCount, 1))"), tint: colors.accent)
                PlateaChip(text: "\(Int(state.overallFraction * 100))%")
                if let current = state.stages.first(where: { $0.k == state.current }) {
                    PlateaChip(text: stageLabel(current.name))
                    if current.fraction == nil, let started = current.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            PlateaChip(text: String(localized: "in corso da \(duration(context.date.timeIntervalSince(started)))"))
                        }
                    }
                }
            } else if model.game(id: gameID).flatMap({ model.buildInfo(for: $0).error }) != nil {
                PlateaChip(text: String(localized: "Interrotta"), tint: .red)
            }
            if !state.warnings.isEmpty && done { PlateaChip(text: String(localized: "\(state.warnings.count) avvisi"), tint: colors.warning) }
        }
    }

    @ViewBuilder private func actions(_ game: Game, building: Bool, done: Bool) -> some View {
        let info = model.buildInfo(for: game)
        HStack(spacing: 10) {
            if building {
                Button { model.cancelBuild(of: game) } label: { Label("Annulla la costruzione", systemImage: "xmark") }
                    .buttonStyle(PlateaButtonStyle(destructive: true))
            } else if done {
                Button { model.play(game) } label: { Label("Gioca", systemImage: "play.fill") }
                    .buttonStyle(PlateaButtonStyle(primary: true)).disabled(model.runningGameID != nil)
                Button("Mostra nel Finder") { if let app = game.nativeApp { NSWorkspace.shared.activateFileViewerSelecting([app]) } }
                    .buttonStyle(PlateaButtonStyle())
            } else {
                Button { model.retryBuild(game) } label: { Label("Riprova", systemImage: "arrow.clockwise") }
                    .buttonStyle(PlateaButtonStyle(primary: true)).disabled(!info.canRetry)
            }
            if let log = info.log {
                Button("Registro completo") { NSWorkspace.shared.open(log) }.buttonStyle(PlateaButtonStyle())
            }
        }
        if let error = info.error, !building {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 12.5))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }
    }

    // MARK: Cards

    private func stagesCard(_ state: NXBuildState, game: Game, building: Bool, done: Bool) -> some View {
        let count = max(state.stageCount, state.stages.count)
        return card("FASI", trailing: building && count > 0 ? "\(state.stages.filter(\.finished).count)/\(count)" : nil) {
            // A build that stopped before its first stage (files out of reach, say) has no stages to list.
            if count == 0 {
                if !done {
                    row(icon: building ? "circle.dotted" : "circle", color: colors.secondary,
                        title: building ? String(localized: "Avvio del motore…") : String(localized: "Non ancora avviata"), detail: nil, time: nil, current: building)
                }
            } else {
                ForEach(1...count, id: \.self) { k in
                    if let stage = state.stages.first(where: { $0.k == k }) {
                        row(icon: stage.finished ? (stage.ok ? (stage.warn ? "exclamationmark.triangle" : "checkmark") : "xmark") : "circle.dotted",
                            color: stage.finished ? (stage.ok ? (stage.warn ? colors.warning : colors.ok) : .red) : colors.accent,
                            title: stageLabel(stage.name),
                            detail: stage.finished ? (stage.summary.isEmpty ? nil : stage.summary) : detail(stage) ?? longStageNote(stage),
                            time: stage.finished ? duration(stage.elapsed) : nil,
                            current: !stage.finished && state.current == k && building)
                    } else {
                        row(icon: "circle", color: colors.secondary, title: String(localized: "Fase \(k)"), detail: nil, time: nil, current: false).opacity(0.5)
                    }
                }
            }
            row(icon: done ? "checkmark" : "circle", color: done ? colors.ok : colors.secondary,
                title: String(localized: "Aggiunta alla libreria"), detail: nil, time: nil, current: false)
                .opacity(done ? 1 : 0.5)
        }
    }

    private func logCard(_ state: NXBuildState, game: Game) -> some View {
        card("REGISTRO", trailing: nil) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showsLog.toggle() } } label: {
                Label(showsLog ? String(localized: "Nascondi") : String(localized: "Mostra le ultime righe"), systemImage: showsLog ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(colors.secondary)
            if showsLog {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(state.log.suffix(10).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("✓") ? colors.ok : line.contains("[RED]") || line.hasPrefix("✗") ? .red : colors.secondary)
                            .lineLimit(2).truncationMode(.middle)
                    }
                }
                .textSelection(.enabled)
            }
        }
    }

    private func card<Content: View>(_ title: LocalizedStringKey, trailing: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 10.5, weight: .semibold)).tracking(1.8).foregroundStyle(colors.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 11, design: .monospaced)).foregroundStyle(colors.secondary) }
            }
            content()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.line))
    }

    private func row(icon: String, color: Color, title: String, detail: String?, time: String?, current: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: current ? .semibold : .regular)).foregroundStyle(colors.fg)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(colors.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            if let time { Text(time).font(.system(size: 11, design: .monospaced)).foregroundStyle(colors.secondary) }
        }
        .padding(.vertical, 3)
    }

    private func detail(_ stage: NXBuildState.Stage) -> String? {
        var parts: [String] = []
        if !stage.step.isEmpty { parts.append(stage.step) }
        if let done = stage.done {
            parts.append(amount(done, unit: stage.unit) + (stage.total.map { " / " + amount($0, unit: stage.unit) } ?? ""))
        }
        if let fraction = stage.fraction { parts.append("\(Int(fraction * 100))%") }
        if let eta = stage.eta { parts.append(String(localized: "ancora \(duration(eta))")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A stage that sends no progress (the pipeline archive can take an hour): say so, so it does not look stuck.
    private func longStageNote(_ stage: NXBuildState.Stage) -> String? {
        guard stage.fraction == nil else { return nil }
        if stage.name == "Pipeline archive" {
            return String(localized: "Fase senza avanzamento: nei giochi grandi dura anche un'ora.")
        }
        return String(localized: "Il motore non dice a che punto è questa fase.")
    }

    private func amount(_ value: Double, unit: String) -> String {
        if unit == "B" { return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
        return Int(value).formatted() + (unit.isEmpty ? "" : " \(unit)")
    }

    private func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return "\(Int(seconds / 3600)) h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) min"
    }
}

/// The engine's stage names, in the user's language.
func stageLabel(_ name: String) -> String {
    switch name {
    case "build nx_extract": return String(localized: "Preparazione degli strumenti")
    case "rewrite": return String(localized: "Riscrittura del codice")
    case "shader split": return String(localized: "Divisione degli shader")
    case "address regions": return String(localized: "Controllo della memoria")
    case "Mac shaders": return String(localized: "Shader per Metal")
    case "Mac host": return String(localized: "Programma Mac")
    case "Pipeline archive": return String(localized: "Archivio delle pipeline")
    case "Mac app": return String(localized: "Pacchetto dell'app Mac")
    default:
        if name.hasPrefix("extract") { return String(localized: "Estrazione del gioco") + " (\(name.dropFirst("extract".count).trimmingCharacters(in: .whitespaces)))" }
        if name.hasPrefix("check") { return String(localized: "Controllo dei file") }
        if name.hasPrefix("survey") { return String(localized: "Analisi del gioco") }
        return name
    }
}
