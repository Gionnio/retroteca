import SwiftUI
import AppKit
import GameController

/// The pad's focus on the top bar and on the pages without a navigation of their own (Library, Builds, Settings,
/// a game's Options, a build). Every button, switch and choice tagged with `padTarget` reports where it is on
/// screen; the arrows go to the nearest one in that direction and A presses it, as on a console.
@MainActor
final class PadFocus: ObservableObject {
    struct Target {
        var frame: CGRect
        var bar: Bool
        var key: String?
        var enabled: Bool
        var action: () -> Void
    }

    private var targets: [UUID: Target] = [:]
    @Published private(set) var focusedID: UUID?
    /// The bar item matching the page on screen ("vetrina", "grid", "builds", "settings", "profile").
    var currentKey: () -> String? = { nil }

    var inBar: Bool { focusedID.flatMap { targets[$0]?.bar } ?? false }

    // MARK: Registration (from `padTarget`)

    func register(_ id: UUID, _ target: Target) { targets[id] = target }

    func update(_ id: UUID, frame: CGRect) { targets[id]?.frame = frame }

    /// Keeps the latest action and state of a target (its view was redrawn).
    func refresh(_ id: UUID, enabled: Bool, action: @escaping () -> Void) {
        targets[id]?.enabled = enabled
        targets[id]?.action = action
    }

    func remove(_ id: UUID) {
        targets[id] = nil
        if focusedID == id { focusedID = nil }
    }

    /// A new page: the focus starts again from its first control, unless it is on the bar (which stays).
    func pageChanged() { if !inBar { focusedID = nil } }

    func clear() { focusedID = nil }

    // MARK: Moving

    func focusBar() {
        let bar = targets.filter { $0.value.bar && $0.value.enabled }
        guard !bar.isEmpty else { return }
        let key = currentKey()
        let pick = bar.first { key != nil && $0.value.key == key }?.key
            ?? bar.min { $0.value.frame.minX < $1.value.frame.minX }!.key
        InterfaceSound.move.play()
        focusedID = pick
    }

    /// Up, down, left, right, A and B. Returns false when it has nothing to do with the command.
    /// `pageHasFocus`: the page on screen moves its own focus (Home, Profile, a game's page), so leaving the bar
    /// gives the focus back to it instead of picking a control here.
    @discardableResult
    func handle(_ command: NavCommand, pageHasFocus: Bool) -> Bool {
        switch command {
        case .up, .down, .left, .right:
            if inBar, command == .down { leaveBar(pageHasFocus: pageHasFocus); return true }
            if inBar, command == .up { InterfaceSound.blocked.play(); return true }
            return move(command)
        case .select:
            guard let id = focusedID, let target = targets[id], target.enabled else { return false }
            InterfaceSound.select.play()
            target.action()
            return true
        case .back:
            guard inBar else { return false }
            leaveBar(pageHasFocus: pageHasFocus)
            return true
        default:
            return false
        }
    }

    private func leaveBar(pageHasFocus: Bool) {
        InterfaceSound.back.play()
        let from = focusedID.flatMap { targets[$0]?.frame }
        focusedID = nil
        guard !pageHasFocus, let from else { return }
        focusedID = best(from: from, .down, among: pageTargets)
    }

    private var pageTargets: [UUID: Target] { targets.filter { !$0.value.bar && $0.value.enabled } }

    private func move(_ command: NavCommand) -> Bool {
        guard let id = focusedID, let current = targets[id] else {
            // Nothing focused yet: up goes to the top bar (also on a page with nothing to press),
            // the other arrows to the page's first control, top left.
            if command == .up { focusBar(); return true }
            let page = pageTargets
            guard let first = page.min(by: { a, b in
                let ay = (a.value.frame.minY / 24).rounded(), by = (b.value.frame.minY / 24).rounded()
                return ay != by ? ay < by : a.value.frame.minX < b.value.frame.minX
            }) else { return false }
            InterfaceSound.move.play()
            focusedID = first.key
            return true
        }
        let pool = current.bar ? targets.filter { $0.value.bar && $0.value.enabled } : pageTargets
        if let next = best(from: current.frame, command, among: pool.filter { $0.key != id }) {
            InterfaceSound.move.play()
            focusedID = next
        } else if command == .up, !current.bar {
            focusBar()
        } else {
            InterfaceSound.blocked.play()
        }
        return true
    }

    /// The nearest target in a direction: distance along it, plus a heavier price for being off to the side.
    private func best(from: CGRect, _ command: NavCommand, among pool: [UUID: Target]) -> UUID? {
        let slack: CGFloat = 8
        func gap(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> CGFloat {
            if a.overlaps(b) { return 0 }
            return a.upperBound < b.lowerBound ? b.lowerBound - a.upperBound : a.lowerBound - b.upperBound
        }
        var bestID: UUID?, bestScore = CGFloat.infinity
        for (id, target) in pool {
            let to = target.frame
            let primary: CGFloat, side: CGFloat, offset: CGFloat
            switch command {
            case .right:
                guard to.minX >= from.maxX - slack else { continue }
                primary = max(0, to.minX - from.maxX); side = gap(from.minY...from.maxY, to.minY...to.maxY); offset = abs(to.midY - from.midY)
            case .left:
                guard to.maxX <= from.minX + slack else { continue }
                primary = max(0, from.minX - to.maxX); side = gap(from.minY...from.maxY, to.minY...to.maxY); offset = abs(to.midY - from.midY)
            case .down:
                guard to.minY >= from.maxY - slack else { continue }
                primary = max(0, to.minY - from.maxY); side = gap(from.minX...from.maxX, to.minX...to.maxX); offset = abs(to.minX - from.minX)
            case .up:
                guard to.maxY <= from.minY + slack else { continue }
                primary = max(0, from.minY - to.maxY); side = gap(from.minX...from.maxX, to.minX...to.maxX); offset = abs(to.minX - from.minX)
            default: return nil
            }
            let score = primary + side * 3 + offset * 0.1
            if score < bestScore { bestScore = score; bestID = id }
        }
        return bestID
    }
}

// MARK: - Targets

private struct PadFocusKey: EnvironmentKey {
    static let defaultValue: PadFocus? = nil
}

extension EnvironmentValues {
    var padFocus: PadFocus? {
        get { self[PadFocusKey.self] }
        set { self[PadFocusKey.self] = newValue }
    }
}

extension View {
    /// Makes this control reachable with the pad: a white ring when focused, A runs `action`.
    func padTarget(bar: Bool = false, key: String? = nil, radius: CGFloat = 9, action: @escaping () -> Void) -> some View {
        modifier(PadTargetModifier(bar: bar, key: key, radius: radius, action: action))
    }
}

private struct PadTargetModifier: ViewModifier {
    @Environment(\.padFocus) private var pad
    let bar: Bool
    let key: String?
    let radius: CGFloat
    let action: () -> Void

    func body(content: Content) -> some View {
        if let pad {
            PadTargetView(pad: pad, bar: bar, key: key, radius: radius, action: action) { content }
        } else {
            content
        }
    }
}

private struct PadTargetView<Content: View>: View {
    @ObservedObject var pad: PadFocus
    @Environment(\.isEnabled) private var isEnabled
    @State private var id = UUID()
    let bar: Bool
    let key: String?
    let radius: CGFloat
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        let on = pad.focusedID == id
        let _ = pad.refresh(id, enabled: isEnabled, action: action)
        content()
            .padFocus(on, radius: radius)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { pad.register(id, .init(frame: geo.frame(in: .global), bar: bar, key: key, enabled: isEnabled, action: action)) }
                    .onChange(of: geo.frame(in: .global)) { _, frame in pad.update(id, frame: frame) }
            })
            .background(RevealWhenFocused(on: on))
            .onDisappear { pad.remove(id) }
    }
}

/// Scrolls the focused control into view when it sits in a scroll view.
private struct RevealWhenFocused: NSViewRepresentable {
    let on: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard on else { return }
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                view.scrollToVisible(view.bounds.insetBy(dx: 0, dy: -80))
            }
        }
    }
}

/// A switch the pad can flip with A.
struct PadSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch)
            .padTarget(radius: 10) { configuration.isOn.toggle() }
    }
}

extension ToggleStyle where Self == PadSwitchToggleStyle {
    static var padSwitch: PadSwitchToggleStyle { PadSwitchToggleStyle() }
}

/// A page whose controls the pad reaches through `PadFocus`: the arrows and Return of the keyboard do the same.
struct PadPage: ViewModifier {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear { focused = true }
            .onKeyPress(.leftArrow) { model.navigate(.left); return .handled }
            .onKeyPress(.rightArrow) { model.navigate(.right); return .handled }
            .onKeyPress(.upArrow) { model.navigate(.up); return .handled }
            .onKeyPress(.downArrow) { model.navigate(.down); return .handled }
            .onKeyPress(.return) { model.padFocus.handle(.select, pageHasFocus: false) ? .handled : .ignored }
    }
}

extension View {
    func padPage() -> some View { modifier(PadPage()) }
}

// MARK: - Button symbols

/// The symbol a connected pad prints on a button, so the hints read ✕ ○ △ on a PlayStation pad,
/// A B Y on an Xbox one, and so on. Falls back to the letter.
enum PadGlyph {
    static func symbol(for letter: String) -> String? {
        guard let pad = GCController.controllers().first?.extendedGamepad else { return nil }
        switch letter {
        case "A": return pad.buttonA.sfSymbolsName
        case "B": return pad.buttonB.sfSymbolsName
        case "X": return pad.buttonX.sfSymbolsName
        case "Y": return pad.buttonY.sfSymbolsName
        case "L": return pad.leftShoulder.sfSymbolsName
        case "R": return pad.rightShoulder.sfSymbolsName
        case "☰": return pad.buttonMenu.sfSymbolsName
        default: return nil
        }
    }
}

// MARK: - Plain buttons, links and checkboxes the pad can press

/// `.plain`, reachable with the pad.
struct PadPlainButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PadButtonBody(configuration: configuration, link: false)
    }
}

/// `.link`, reachable with the pad.
struct PadLinkButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PadButtonBody(configuration: configuration, link: true)
    }
}

extension PrimitiveButtonStyle where Self == PadPlainButtonStyle {
    static var padPlain: PadPlainButtonStyle { PadPlainButtonStyle() }
}

extension PrimitiveButtonStyle where Self == PadLinkButtonStyle {
    static var padLink: PadLinkButtonStyle { PadLinkButtonStyle() }
}

private struct PadButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: PrimitiveButtonStyleConfiguration
    let link: Bool

    var body: some View {
        Group {
            if link { configuration.label.foregroundStyle(Color.accentColor) } else { configuration.label }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { configuration.trigger() } }
        .padTarget(radius: 6) { configuration.trigger() }
    }
}

/// A checkbox the pad can tick with A.
struct PadCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.checkbox)
            .padTarget(radius: 6) { configuration.isOn.toggle() }
    }
}

extension ToggleStyle where Self == PadCheckboxToggleStyle {
    static var padCheckbox: PadCheckboxToggleStyle { PadCheckboxToggleStyle() }
}

extension View {
    /// A menu or picker with the pad: A picks the next of `values` after `current`.
    func padCycle<V: Equatable>(_ values: [V], current: V, set: @escaping (V) -> Void) -> some View {
        padTarget(radius: 7) {
            guard !values.isEmpty else { return }
            set(values[((values.firstIndex(of: current) ?? -1) + 1) % values.count])
        }
    }
}
