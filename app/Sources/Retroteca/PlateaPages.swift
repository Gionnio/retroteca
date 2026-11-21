import SwiftUI
import RetrotecaCore

/// "Libreria  214 giochi", as on the Film page of Platea.
struct PageTitle: View {
    @Environment(\.platea) private var colors
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 26, weight: .bold)).foregroundStyle(colors.fg)
            Text(detail).foregroundStyle(colors.secondary)
        }
    }
}

/// "‹ Indietro", also on Esc.
struct BackButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    /// A screenshot open above: Esc closes it, not the page.
    var viewerOpen = false

    var body: some View {
        Button { model.back() } label: { Label("Indietro", systemImage: "chevron.left") }
            .buttonStyle(.plain).foregroundStyle(colors.secondary).font(.system(size: 12))
            .keyboardShortcut(.cancelAction)
            .disabled(viewerOpen)
            .padding(.bottom, 14)
    }
}

/// A box cover in a fixed portrait frame: the whole image over a blurred fill, or a generated one.
struct BoxArt: View {
    let url: URL?
    let title: String

    var body: some View {
        NameArt(title: title, image: url, fit: true)
            .aspectRatio(0.72, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Artwork for anything with a name: an image when there is one, otherwise a backdrop generated in the name's colour.
struct NameArt: View {
    let title: String
    var image: URL?
    var backdrop = false
    /// Covers: the whole image fitted, over a blurred fill.
    var fit = false

    var body: some View {
        generated
            .overlay {
                if let image, let picture = ArtworkCache.image(at: image) {
                    if fit {
                        Image(nsImage: picture).resizable().interpolation(.high).scaledToFit()
                            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background { Image(nsImage: picture).resizable().scaledToFill().blur(radius: 14, opaque: true).opacity(0.85) }
                    } else {
                        Image(nsImage: picture).resizable().interpolation(.high).scaledToFill()
                            .blur(radius: backdrop ? backdropBlurRadius(picture) : 0, opaque: true)
                    }
                } else if !backdrop {
                    Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 3, y: 1).lineLimit(3).padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .clipped()
    }

    private var generated: some View {
        let hue = stableHue(title)
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

/// Messages and work in progress, in a capsule at the bottom of the window (in place of a status bar).
struct ToastOverlay: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    @State private var visibleMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let busy = busyText {
                // A click opens the page of the work in progress.
                Button { if let target = busyTarget { model.open(target) } } label: {
                    capsule { ProgressView().controlSize(.small); Text(busy); if busyTarget != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(colors.secondary) } }
                }
                .buttonStyle(.plain)
                .disabled(busyTarget == nil)
            }
            if let visibleMessage {
                capsule { Text(visibleMessage) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .padding(.leading, 28).padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .task(id: model.message) {
            guard let message = model.message else { return }
            withAnimation(.easeOut(duration: 0.2)) { visibleMessage = message }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            withAnimation(.easeIn(duration: 0.3)) { visibleMessage = nil }
            if model.message == message { model.message = nil }
        }
    }

    private var busyTarget: Page? {
        model.buildingGameID.map { .build($0) }
    }

    private var busyText: String? {
        if model.isImporting { return String(localized: "Importazione in corso…") }
        if let id = model.buildingGameID, let game = model.game(id: id) {
            let state = model.buildInfo(for: game).state
            return String(localized: "\(game.title): costruzione \(state.current ?? 0)/\(max(state.stageCount, 1)) · \(Int(state.overallFraction * 100))%")
        }
        return model.switchGames.setupText
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .font(.system(size: 12.5)).foregroundStyle(colors.fg)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(colors.line))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}
