import SwiftUI
import RetrotecaCore

/// Cover art, or a tinted placeholder with the initial while there is none.
struct CoverView: View {
    let url: URL?
    let title: String
    var width: CGFloat = 38
    var square = false

    private var height: CGFloat { square ? width : (width * 1.33).rounded() }

    var body: some View {
        Group {
            if let url, let image = ArtworkCache.image(at: url) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: width > 50 ? 8 : 5))
        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
    }

    private var placeholder: some View {
        // Stable colour per title: hashValue changes at every launch.
        let hue = Double(title.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360
        return LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.75), Color(hue: hue, saturation: 0.7, brightness: 0.45)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: width * 0.42, weight: .bold)).foregroundStyle(.white)
            }
    }
}

extension GameKind {
    var label: String {
        switch self {
        case .emulated: return String(localized: "Emulato")
        case .nativePort: return String(localized: "Port nativo")
        case .switchNative: return String(localized: "Switch nativo")
        }
    }

    var color: Color {
        switch self {
        case .emulated: return .purple
        case .nativePort: return .green
        case .switchNative: return .red
        }
    }

    var symbol: String {
        switch self {
        case .emulated: return "cpu"
        case .nativePort: return "hammer"
        case .switchNative: return "gamecontroller"
        }
    }
}

extension GameStatus {
    /// Green ready, orange to install, red missing, blue to recognise.
    var color: Color {
        switch self {
        case .ready: return .green
        case .needsEngine: return .orange
        case .missingFiles: return .red
        case .unrecognized: return .blue
        }
    }

    var label: String {
        switch self {
        case .ready: return String(localized: "Pronto")
        case .needsEngine: return String(localized: "Motore da installare")
        case .missingFiles: return String(localized: "File non trovati")
        case .unrecognized: return String(localized: "Console da riconoscere")
        }
    }
}

/// "1 h 20 min", "12 min", "—".
func formatPlayTime(_ seconds: TimeInterval) -> String {
    guard seconds >= 60 else { return "—" }
    let f = DateComponentsFormatter()
    f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
    f.unitsStyle = .abbreviated
    return f.string(from: seconds) ?? "—"
}

