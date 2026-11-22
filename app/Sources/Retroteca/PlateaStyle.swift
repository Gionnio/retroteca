import SwiftUI
import ImageIO
import RetrotecaCore

/// Colours of the Vetrina pages, as in Platea Home: Grafite, Giorno, Notte blu, Auto.
enum PlateaPalette: String, CaseIterable, Identifiable {
    case grafite, giorno, notte, auto
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .grafite: return "Grafite"
        case .giorno: return "Giorno"
        case .notte: return "Notte blu"
        case .auto: return "Auto"
        }
    }

    var name: String {
        switch self {
        case .grafite: return String(localized: "Grafite")
        case .giorno: return String(localized: "Giorno")
        case .notte: return String(localized: "Notte blu")
        case .auto: return String(localized: "Auto")
        }
    }

    /// Auto: Giorno from 7 to 19, Notte blu otherwise.
    func resolved(at date: Date = Date()) -> PlateaPalette {
        guard self == .auto else { return self }
        let hour = Calendar.current.component(.hour, from: date)
        return (7..<19).contains(hour) ? .giorno : .notte
    }

    var colors: PlateaColors {
        switch resolved() {
        case .giorno:
            return PlateaColors(bg: Color(hex: 0xECEDF0), bg2: Color(hex: 0xE2E3E8), fg: Color(hex: 0x121214), secondary: Color(hex: 0x62626A),
                                accent: Color(hex: 0xC2741F), line: .black.opacity(0.1), card: .black.opacity(0.05), isDark: false)
        case .notte:
            return PlateaColors(bg: Color(hex: 0x0D1526), bg2: Color(hex: 0x14203A), fg: Color(hex: 0xEEF3FF), secondary: Color(hex: 0x9FB0CF),
                                accent: Color(hex: 0x7FB2FF), line: .white.opacity(0.12), card: .white.opacity(0.07), isDark: true)
        default:
            return PlateaColors(bg: Color(hex: 0x141214), bg2: Color(hex: 0x1D1A1D), fg: Color(hex: 0xF4F1EE), secondary: Color(hex: 0xA9A2A0),
                                accent: Color(hex: 0xE0A85A), line: .white.opacity(0.12), card: .white.opacity(0.07), isDark: true)
        }
    }
}

struct PlateaColors {
    let bg, bg2, fg, secondary, accent: Color
    let line, card: Color
    let isDark: Bool
    let ok = Color(hex: 0x3FB27F)
    let warning = Color(hex: 0xF08C00)
}

private struct PlateaColorsKey: EnvironmentKey {
    static let defaultValue = PlateaPalette.grafite.colors
}

extension EnvironmentValues {
    var platea: PlateaColors {
        get { self[PlateaColorsKey.self] }
        set { self[PlateaColorsKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Stable hue for a title (hashValue changes at every launch).
func stableHue(_ text: String) -> Double {
    Double(text.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360
}

/// Game artwork. Wide places (Vetrina, tiles) prefer the screenshot, box places the cover;
/// without artwork, a generated backdrop in the title's colour.
struct GameArt: View {
    let game: Game
    var wide = true
    /// Fills the whole window: large images stay sharp under the shade, small ones (libretro snaps, icons) are blurred.
    var backdrop = false

    /// Whether real artwork is shown (titles written over generated art only).
    static func hasImage(_ game: Game, wide: Bool = true) -> Bool {
        (wide ? (game.backdropURL ?? game.coverURL) : (game.coverURL ?? game.backdropURL)) != nil
    }

    var body: some View {
        // The image is an overlay of the generated art: it fills the space it is given and never sizes it.
        generated
            .overlay {
                if let url = wide ? (game.backdropURL ?? game.coverURL) : (game.coverURL ?? game.backdropURL),
                   let image = ArtworkCache.image(at: url) {
                    if wide {
                        Image(nsImage: image)
                            .resizable().interpolation(.high).scaledToFill()
                            .blur(radius: backdrop ? backdropBlur(image) : 0, opaque: true)
                            .saturation(backdrop && backdropBlur(image) > 0 ? 1.15 : 1)
                    } else {
                        // Boxes come in every shape (SNES and GBA are wide): the whole cover, over a blurred fill.
                        // The fitted cover sets the size; the blurred fill only sits behind it.
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background {
                                Image(nsImage: image).resizable().scaledToFill().blur(radius: 14, opaque: true).opacity(0.85)
                            }
                    }
                }
            }
            .clipped()
    }

    private func backdropBlur(_ image: NSImage) -> CGFloat { backdropBlurRadius(image) }

    private var generated: some View {
        let hue = stableHue(game.title)
        let second = (hue + 0.55).truncatingRemainder(dividingBy: 1)
        return GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.16), Color(hue: second, saturation: 0.45, brightness: 0.13)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(hue: hue, saturation: 0.6, brightness: 0.95), Color(hue: hue, saturation: 0.75, brightness: 0.45).opacity(0.6), .clear],
                               center: UnitPoint(x: 0.72, y: 0.36), startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.55)
                RadialGradient(colors: [Color(hue: second, saturation: 0.55, brightness: 0.75).opacity(0.75), .clear],
                               center: UnitPoint(x: 0.6, y: 0.78), startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.38)
            }
        }
    }
}

/// Small coloured caps line above titles ("CONTINUA A GIOCARE").
struct Kicker: View {
    @Environment(\.platea) private var colors
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold)).tracking(1.8)
            .foregroundStyle(colors.accent)
    }
}

/// "HD"-like chip, or the green/orange status capsule ("✓ Pronto · App Mac nativa").
struct PlateaChip: View {
    @Environment(\.platea) private var colors
    let text: String
    var tint: Color?

    var body: some View {
        if let tint {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 9).padding(.vertical, 2.5)
                .background(tint.opacity(0.2), in: Capsule())
        } else {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.4)
                .foregroundStyle(colors.fg)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(colors.line))
        }
    }
}

/// White "Riproduci"-style button, and the outlined one.
struct PlateaButtonStyle: ButtonStyle {
    @Environment(\.platea) private var colors
    @Environment(\.isEnabled) private var isEnabled
    var primary = false
    /// Destructive actions (cancel a build): red text, as in the mockups.
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 9)
            .foregroundStyle(primary ? colors.bg : destructive ? Color(red: 1, green: 0.42, blue: 0.42) : colors.fg)
            .background(primary ? colors.fg : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(primary ? .clear : colors.line, lineWidth: 1.5))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Filter pill, with the accent outline when active.
struct PillButton: View {
    @Environment(\.platea) private var colors
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: isOn ? .semibold : .regular))
                .foregroundStyle(colors.fg)
                .padding(.horizontal, 13).padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(isOn ? colors.accent : colors.line, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// How much a full-window image is blurred: none when it is large enough to stay sharp (Nintendo banners,
/// 1600 px), some for libretro snaps (about 640 px), more for icons (256 px).
func backdropBlurRadius(_ image: NSImage) -> CGFloat {
    let width = CGFloat(image.representations.map(\.pixelsWide).max() ?? Int(image.size.width))
    return width >= 1100 ? 0 : (width < 400 ? 48 : 18)
}

/// The left and bottom fade over a full-window image, as in Platea.
struct BackdropShade: View {
    @Environment(\.platea) private var colors
    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: colors.bg, location: 0), .init(color: colors.bg.opacity(0.85), location: 0.35), .init(color: .clear, location: 0.72)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: colors.bg, location: 0.05), .init(color: colors.bg.opacity(0.6), location: 0.4), .init(color: .clear, location: 0.66)],
                           startPoint: .bottom, endPoint: .top)
        }
    }
}

extension View {
    /// A page scrolling up fades out before it reaches the pills, so text never runs into the top bar
    /// while the image behind stays whole.
    func fadesUnderTopBar() -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.8), .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 76)
                Color.black
            }
        }
    }
}

/// Status symbol over a cover: ▶ played, ! something missing, ⤓ to install.
struct StatusBadge: View {
    let game: Game
    var body: some View {
        let (symbol, color): (String?, Color) = {
            switch game.status {
            case .missingFiles: return ("exclamationmark", .red)
            case .unrecognized: return ("questionmark", .blue)
            case .needsEngine: return ("arrow.down", .orange)
            case .ready: return (game.lastPlayedAt != nil ? "play.fill" : nil, .black.opacity(0.55))
            }
        }()
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(color, in: Circle())
                .padding(7)
        }
    }
}

/// Artwork decoded once, at most as large as a window needs, and kept in memory: drawing never waits for a JPEG to decode.
/// The Home page decodes its games' images ahead, off the main thread, so moving between games swaps pictures at once.
enum ArtworkCache {
    /// Longest side kept: sharp on a full-window backdrop, a fraction of the memory of a store original.
    static let maxPixels = 2048

    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = 512 << 20
        return cache
    }()
    private static let queue = DispatchQueue(label: "com.github.gionnio.Retroteca.artwork", qos: .userInitiated, attributes: .concurrent)

    static func image(at url: URL) -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard let (image, cost) = decode(url) else { return nil }
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    /// Decodes these images in the background, the ones not in memory yet.
    static func prefetch(_ urls: [URL]) {
        for url in urls where cache.object(forKey: url as NSURL) == nil {
            queue.async {
                guard cache.object(forKey: url as NSURL) == nil, let (image, cost) = decode(url) else { return }
                cache.setObject(image, forKey: url as NSURL, cost: cost)
            }
        }
    }

    /// A bitmap decoded now (not when first drawn), downsampled to `maxPixels`.
    private static func decode(_ url: URL) -> (NSImage, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return (image, cgImage.bytesPerRow * cgImage.height)
    }

    /// After the file at `url` was replaced.
    static func forget(_ url: URL) { cache.removeObject(forKey: url as NSURL) }
}
