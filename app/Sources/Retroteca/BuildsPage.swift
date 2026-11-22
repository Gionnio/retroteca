import SwiftUI
import RetrotecaCore

/// "Costruzioni": the build running now, the queue, paused, ready and failed builds — like a console's downloads page.
struct BuildsPageView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors

    var body: some View {
        let running = model.switchGames.buildingID.flatMap(model.game(id:))
        ZStack(alignment: .topLeading) {
            if let running {
                GameArt(game: running, backdrop: true).ignoresSafeArea().opacity(0.25).blur(radius: 30)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Costruzioni").font(.system(size: 34, weight: .bold)).foregroundStyle(colors.fg)
                    HStack(alignment: .top, spacing: 20) {
                        Group {
                            if let running { RunningBuildCard(game: running) } else { idle }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 10) {
                            section(String(localized: "IN CODA"), ids: model.buildQueue) { game in
                                AnyView(HStack(spacing: 6) {
                                    smallButton("arrow.up", help: String(localized: "Sposta in cima")) { model.moveToFront(game.id) }
                                    smallButton("xmark", help: String(localized: "Togli dalla coda")) { model.removeFromQueue(game.id) }
                                })
                            }
                            section(String(localized: "IN PAUSA"), ids: Array(model.pausedBuilds)) { game in
                                AnyView(HStack(spacing: 6) {
                                    Button(String(localized: "Riprendi")) { model.resumeBuild(game) }.buttonStyle(PlateaButtonStyle()).controlSize(.small)
                                    smallButton("xmark", help: String(localized: "Togli")) { model.removeFromQueue(game.id) }
                                })
                            }
                            history
                            if model.buildQueue.isEmpty && model.pausedBuilds.isEmpty && model.buildHistory.isEmpty {
                                Text("Niente in coda. Scegli un gioco da costruire nella Libreria.")
                                    .font(.system(size: 13)).foregroundStyle(colors.secondary).padding(.top, 4)
                            }
                        }
                        .frame(width: 420, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 48).padding(.top, PageLayout.top).padding(.bottom, 40)
            }
            .fadesUnderTopBar()
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "hammer").font(.system(size: 30)).foregroundStyle(colors.secondary)
            Text("Nessuna costruzione in corso").font(.system(size: 18, weight: .semibold)).foregroundStyle(colors.fg)
            Text("Le costruzioni partono una alla volta; le altre aspettano qui.").font(.system(size: 13)).foregroundStyle(colors.secondary)
        }
        .padding(24).frame(maxWidth: .infinity, minHeight: 260, alignment: .bottomLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(colors.line))
    }

    @ViewBuilder private func section(_ title: String, ids: [UUID], trailing: @escaping (Game) -> AnyView) -> some View {
        let games = ids.compactMap(model.game(id:))
        if !games.isEmpty {
            Text(title).font(.system(size: 10.5, weight: .semibold)).tracking(1.8).foregroundStyle(colors.secondary).padding(.top, 4)
            ForEach(games) { game in
                BuildRow(game: game, line: line(for: game)) { trailing(game) }
            }
        }
    }

    @ViewBuilder private var history: some View {
        let ready = model.buildHistory.filter { $0.outcome == .built }
        let failed = model.buildHistory.filter { if case .failed = $0.outcome { return true } else { return false } }
        if !ready.isEmpty {
            Text("PRONTE").font(.system(size: 10.5, weight: .semibold)).tracking(1.8).foregroundStyle(colors.secondary).padding(.top, 4)
            ForEach(ready) { record in
                if let game = model.game(id: record.gameID) {
                    BuildRow(game: game, line: String(localized: "\(record.date.formatted(date: .omitted, time: .shortened)) · \(formatPlayTime(record.duration))"), ready: true) {
                        Button { model.play(game) } label: { Label("Gioca", systemImage: "play.fill") }.buttonStyle(PlateaButtonStyle()).controlSize(.small)
                    }
                }
            }
        }
        if !failed.isEmpty {
            Text("NON RIUSCITE").font(.system(size: 10.5, weight: .semibold)).tracking(1.8).foregroundStyle(colors.secondary).padding(.top, 4)
            ForEach(failed) { record in
                if let game = model.game(id: record.gameID), case .failed(let reason) = record.outcome {
                    BuildRow(game: game, line: reason) {
                        Button(String(localized: "Riprova")) { model.queueBuild(game) }.buttonStyle(PlateaButtonStyle()).controlSize(.small)
                    }
                }
            }
        }
    }

    private func line(for game: Game) -> String {
        switch model.buildStage(game) {
        case .queued(let position): return String(localized: "\(position)° in coda")
        case .paused(let fraction): return String(localized: "In pausa · \(Int(fraction * 100))%")
        default: return game.size > 0 ? ByteCountFormatter.string(fromByteCount: game.size, countStyle: .file) : ""
        }
    }

    private func smallButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 14, height: 14) }
            .buttonStyle(PlateaButtonStyle()).controlSize(.small).help(help)
    }
}

/// The build running now, large: art, title, stages as segments, time left, pause / cancel / follow.
private struct RunningBuildCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game

    var body: some View {
        let state = model.switchGames.builds[game.id] ?? NXBuildState()
        let count = max(state.stageCount, state.stages.count, 1)
        ZStack(alignment: .bottomLeading) {
            GameArt(game: game, backdrop: true).opacity(0.7)
            LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .bottom, endPoint: .center)
            VStack(alignment: .leading, spacing: 8) {
                Kicker(text: String(localized: "In costruzione · \(Int(state.overallFraction * 100))%"))
                Text(game.title).font(.system(size: 26, weight: .heavy)).foregroundStyle(.white).lineLimit(2)
                if let stage = state.current.flatMap({ k in state.stages.first { $0.k == k } }) {
                    Text("\(stageLabel(stage.name)) · \(stage.k) di \(count)" + (stage.eta.map { " · " + String(localized: "circa \(formatPlayTime($0))") } ?? ""))
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                }
                HStack(spacing: 5) {
                    ForEach(1...count, id: \.self) { k in
                        let stage = state.stages.first { $0.k == k }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.18))
                                Capsule().fill(stage?.finished == true ? colors.ok : colors.accent)
                                    .frame(width: geo.size.width * (stage?.finished == true ? 1 : (stage?.fraction ?? 0)))
                            }
                        }
                        .frame(height: 5)
                    }
                }
                .padding(.vertical, 4)
                HStack(spacing: 10) {
                    Button { model.pauseBuild(game) } label: { Label("Pausa", systemImage: "pause.fill") }.buttonStyle(PlateaButtonStyle())
                    Button(String(localized: "Annulla")) { model.cancelBuild(of: game) }.buttonStyle(PlateaButtonStyle(destructive: true))
                    Button(String(localized: "Segui")) { model.open(.build(game.id)) }.buttonStyle(PlateaButtonStyle())
                }
                .padding(.top, 4)
            }
            .padding(22)
        }
        .frame(minHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(colors.line))
    }
}

/// One line of the queue or the history: picture, title, detail, actions.
private struct BuildRow<Trailing: View>: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game
    let line: String
    var ready = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            GameArt(game: game).frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 8))
                .saturation(ready ? 1 : 0.5).brightness(ready ? 0 : -0.1)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.fg).lineLimit(1)
                if !line.isEmpty { Text(line).font(.system(size: 11.5)).foregroundStyle(colors.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.line))
        .contentShape(Rectangle())
        .onTapGesture { model.open(.game(game.id)) }
    }
}
