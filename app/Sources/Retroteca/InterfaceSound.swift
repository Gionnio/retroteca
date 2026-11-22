import AVFoundation

/// Retroteca's own interface sounds (synthesised by tools/make_sounds.py), off from Settings → General.
enum InterfaceSound: String, CaseIterable {
    case move, select, back, page, launch, blocked

    static let settingKey = "interfaceSounds"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    /// A few players per sound, so quick moves overlap instead of cutting each other off.
    @MainActor private static var players: [InterfaceSound: [AVAudioPlayer]] = [:]
    @MainActor private static var next: [InterfaceSound: Int] = [:]

    @MainActor func play() {
        guard Self.isEnabled else { return }
        if Self.players[self] == nil {
            guard let url = Bundle.main.url(forResource: rawValue, withExtension: "wav", subdirectory: "Sounds") else { return }
            Self.players[self] = (0..<3).compactMap { _ in
                let player = try? AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
                return player
            }
        }
        guard let pool = Self.players[self], !pool.isEmpty else { return }
        let index = Self.next[self, default: 0] % pool.count
        Self.next[self] = index + 1
        pool[index].currentTime = 0
        pool[index].play()
    }
}
