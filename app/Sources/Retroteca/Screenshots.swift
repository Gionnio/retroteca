import SwiftUI
import RetrotecaCore

/// The SCHERMATE row of a game page: the game's screenshots, with arrows for the mouse and the raised
/// frame for keyboard and controller moves, as in the Vetrina rows.
struct ScreenshotRow: View {
    @Environment(\.platea) private var colors
    let shots: [URL]
    let source: String
    let focused: Int?
    let open: (Int) -> Void

    @State private var start = 0
    @State private var width: CGFloat = 0
    @State private var hovering = false

    /// Thumbnails that fit in the row (236 wide, 14 apart).
    private var perPage: Int { max(1, Int((width + 14) / 250)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("SCHERMATE").font(.system(size: 10.5, weight: .semibold)).tracking(1.8).foregroundStyle(colors.secondary)
                Text("\(source) · \(shots.count)").font(.system(size: 11.5)).foregroundStyle(colors.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(shots.enumerated()), id: \.offset) { index, url in
                            thumbnail(url, isFocused: index == focused)
                                .onTapGesture { open(index) }
                                .id(index)
                        }
                    }
                    .padding(.vertical, 12).padding(.horizontal, 10)
                }
                .padding(.horizontal, -10)
                .background(GeometryReader { geo in Color.clear.onAppear { width = geo.size.width }.onChange(of: geo.size.width) { _, w in width = w } })
                .overlay(alignment: .leading) {
                    if hovering && start > 0 { arrow("chevron.left") { page(-1, proxy) } }
                }
                .overlay(alignment: .trailing) {
                    if hovering && start + perPage < shots.count { arrow("chevron.right") { page(1, proxy) } }
                }
                .onHover { hovering = $0 }
                .onChange(of: focused) { _, index in
                    guard let index else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index) }
                    if index < start { start = index } else if index >= start + perPage { start = index - perPage + 1 }
                }
            }
        }
    }

    private func thumbnail(_ url: URL, isFocused: Bool) -> some View {
        Group {
            if let image = ArtworkCache.image(at: url) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                colors.card
            }
        }
        .frame(width: 236, height: 133)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(isFocused ? colors.fg : .clear, lineWidth: 2.5).padding(-4))
        .shadow(color: .black.opacity(isFocused ? 0.45 : 0.25), radius: isFocused ? 14 : 2, y: isFocused ? 10 : 1)
        .scaleEffect(isFocused ? 1.04 : 1)
        .offset(y: isFocused ? -4 : 0)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }

    private func page(_ direction: Int, _ proxy: ScrollViewProxy) {
        start = min(max(start + direction * perPage, 0), max(shots.count - perPage, 0))
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(start, anchor: .leading) }
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        RoundArrow(symbol: symbol, action: action).padding(.horizontal, 6)
    }
}

/// A screenshot over the whole window, above the game page: arrows (and ← →, L/R) to move, Esc or B to close.
struct ScreenshotViewer: View {
    @Environment(\.platea) private var colors
    let title: String
    let shots: [URL]
    @Binding var index: Int?

    var body: some View {
        if let current = index, shots.indices.contains(current) {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                colors.bg.opacity(0.88).ignoresSafeArea()
                VStack(spacing: 16) {
                    HStack {
                        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.fg)
                        Spacer()
                        Text("\(current + 1) di \(shots.count)").font(.system(size: 13)).foregroundStyle(colors.secondary)
                        Button { index = nil } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(colors.secondary)
                            .keyboardShortcut(.cancelAction)
                            .padding(.leading, 10)
                    }
                    .padding(.leading, 70)
                    HStack(spacing: 18) {
                        RoundArrow(symbol: "chevron.left") { step(-1) }.opacity(current > 0 ? 1 : 0.3).disabled(current == 0)
                        if let image = ArtworkCache.image(at: shots[current]) {
                            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Spacer()
                        }
                        RoundArrow(symbol: "chevron.right") { step(1) }.opacity(current < shots.count - 1 ? 1 : 0.3).disabled(current == shots.count - 1)
                    }
                    HStack(spacing: 8) {
                        ForEach(Array(shots.enumerated()), id: \.offset) { i, url in
                            Group {
                                if let image = ArtworkCache.image(at: url) { Image(nsImage: image).resizable().scaledToFill() } else { colors.card }
                            }
                            .frame(width: 96, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(i == current ? colors.fg : .clear, lineWidth: 2).padding(-3))
                            .opacity(i == current ? 1 : 0.5)
                            .onTapGesture { index = i }
                        }
                    }
                }
                .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 26)
            }
            .transition(.opacity)
        }
    }

    func step(_ direction: Int) {
        guard let current = index else { return }
        index = min(max(current + direction, 0), shots.count - 1)
    }
}

/// The round arrow of rows and viewers, for the mouse.
struct RoundArrow: View {
    @Environment(\.platea) private var colors
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(colors.fg)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(colors.line))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }
}
