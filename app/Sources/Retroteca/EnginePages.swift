import SwiftUI
import RetrotecaCore

/// The engine that builds Switch games: the commit in use, what the latest one brings for the user's games,
/// and moving to it (or back to the commit Retroteca tested). Games built before show "Aggiornamento da costruire".
struct SwitchEngineCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors

    var body: some View {
        let manager = model.switchGames
        if let engine = manager.engine {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("MOTORE SWITCH").font(.system(size: 10.5, weight: .semibold)).tracking(1.8).foregroundStyle(colors.secondary)
                    Spacer()
                    if manager.checkingEngine || manager.setupText != nil {
                        ProgressView().controlSize(.small)
                    } else if manager.engineUpdate != nil {
                        PlateaChip(text: String(localized: "Aggiornamento disponibile"), tint: colors.accent)
                    } else {
                        PlateaChip(text: "✓ " + String(localized: "Aggiornato"), tint: colors.ok)
                    }
                }
                Text("\(engine.name) \(engine.shortCommit)" + (engine.committedAt.map { " · \($0)" } ?? "")
                     + " · " + versionText)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.fg)
                if let channels = manager.testedEngine?.channels, !channels.isEmpty {
                    HStack(spacing: 8) {
                        Text("Canale").font(.system(size: 12)).foregroundStyle(colors.secondary)
                        PillButton(title: String(localized: "Ufficiale"), isOn: manager.channel == nil) {
                            Task { await manager.selectChannel(nil); await check(force: true) }
                        }
                        ForEach(channels) { channel in
                            PillButton(title: channel.name, isOn: manager.channel?.id == channel.id) {
                                Task { await manager.selectChannel(channel.id); await check(force: true) }
                            }
                        }
                    }
                    .disabled(manager.isBusy || manager.checkingEngine)
                    if let channel = manager.channel {
                        HStack(spacing: 6) {
                            Text(String(localized: "Il motore ufficiale più modifiche non ancora integrate, per i Mac M1 e M2. Non provato dagli autori del motore."))
                                .font(.system(size: 12)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
                            Button(String(localized: "Cosa contiene")) {
                                NSWorkspace.shared.open(URL(string: "https://github.com/\(channel.repo)/blob/\(channel.branch)/RETROTECA.md")!)
                            }
                            .buttonStyle(.link).font(.system(size: 12))
                        }
                    }
                }
                if let update = manager.engineUpdate {
                    Text(summary(update)).font(.system(size: 12)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
                    if update.contractChanged {
                        Label("Cambia anche il protocollo del motore: alcuni dati della costruzione potrebbero mancare.",
                              systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if update.shadersChanged {
                        Label("Cambiano gli shader: per avere le novità ogni gioco va ricostruito da capo, anche per ore. Le app già costruite continuano a funzionare.",
                              systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let text = manager.setupText {
                    Text(text).font(.system(size: 12)).foregroundStyle(colors.secondary)
                } else {
                    Text("Dopo un aggiornamento del motore i giochi vanno ricostruiti.")
                        .font(.system(size: 12)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error = manager.setupError {
                    Label(error, systemImage: "xmark.octagon").font(.system(size: 12)).foregroundStyle(.red)
                }
                HStack(spacing: 10) {
                    if let update = manager.engineUpdate {
                        Button { Task { await manager.updateEngine(); await check(force: true) } } label: {
                            Label(String(localized: "Aggiorna il motore"), systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(PlateaButtonStyle(primary: true)).disabled(manager.isBusy)
                        Button(String(localized: "Le novità")) { NSWorkspace.shared.open(update.compareURL) }.buttonStyle(PlateaButtonStyle())
                    } else {
                        Button(String(localized: "Controlla ora")) { Task { await check(force: true) } }
                            .buttonStyle(PlateaButtonStyle()).disabled(manager.checkingEngine)
                    }
                    if manager.engineOverride != nil {
                        Button(String(localized: "Torna alla versione provata")) { Task { await manager.useTestedEngine(); await check(force: true) } }
                            .buttonStyle(PlateaButtonStyle()).disabled(manager.isBusy)
                    }
                }
                if manager.isBusy, manager.buildingID != nil {
                    Text("Durante una costruzione il motore non si cambia.").font(.system(size: 11)).foregroundStyle(colors.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.line))
            .task { await check(force: false) }
        }
    }

    private var versionText: String {
        let manager = model.switchGames
        if let channel = manager.channel { return String(localized: "canale \(channel.name)") }
        return manager.engineOverride == nil ? String(localized: "la versione provata da Retroteca") : String(localized: "aggiornato da te")
    }

    /// At most every six hours unless asked.
    private func check(force: Bool) async {
        let last = UserDefaults.standard.object(forKey: "engineCheckedAt") as? Date
        guard force || model.switchGames.engineUpdate == nil && (last.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true) else { return }
        let names = model.games.filter { $0.kind == .switchNative }.map { model.switchGames.profile(for: $0)?.name ?? $0.title }
        await model.switchGames.checkEngineUpdate(games: names)
    }

    private func summary(_ update: NXEngineUpdate) -> String {
        var text = update.count == 1 ? String(localized: "1 modifica dopo quella in uso") : String(localized: "\(update.count) modifiche dopo quella in uso")
        if let date = update.latestDate { text += " " + String(localized: "(ultima del \(date))") }
        text += "."
        let games = update.gameMentions.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
        if !games.isEmpty { text += " " + String(localized: "Per i tuoi giochi: \(games.joined(separator: ", ")).") }
        return text
    }
}

