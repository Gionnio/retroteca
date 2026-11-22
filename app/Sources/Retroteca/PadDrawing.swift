import SwiftUI
import RetrotecaCore

/// A generic controller (no maker's shape or symbols) drawn in Settings › Controller, following docs/mockup/controller.html:
/// every control can be clicked to choose its action, lights up when pressed on the real pad, and is named in a callout
/// outside the drawing. Coordinates are in a 900 × 500 design space, scaled to the width available.
struct PadDrawing: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let pad: ConnectedPad
    @State private var editing: String?

    // MARK: Design space

    static let size = CGSize(width: 900, height: 500)
    static let origin = CGPoint(x: 450, y: 112)

    enum Kind { case trigger, bumper, stick, dpad, face, small, home, pill }
    enum Zone { case left, right, top, bottom }

    struct Control: Identifiable {
        let id: String
        let kind: Kind
        /// Centre, relative to `origin`.
        let x: CGFloat, y: CGFloat
        let zone: Zone
        var point: CGPoint { CGPoint(x: PadDrawing.origin.x + x, y: PadDrawing.origin.y + y) }
        var radius: CGFloat {
            switch kind {
            case .stick: return 31
            case .dpad: return 33
            case .face: return 14
            case .small: return 8
            case .home: return 11
            case .pill: return 5
            case .trigger, .bumper: return 0
            }
        }
    }

    static let controls: [Control] = [
        Control(id: "zl", kind: .trigger, x: -150, y: -14, zone: .left),
        Control(id: "l", kind: .bumper, x: -150, y: 14, zone: .left),
        Control(id: "ls", kind: .stick, x: -122, y: 92, zone: .left),
        Control(id: "zr", kind: .trigger, x: 150, y: -14, zone: .right),
        Control(id: "r", kind: .bumper, x: 150, y: 14, zone: .right),
        Control(id: "north", kind: .face, x: 125, y: 60, zone: .right),
        Control(id: "east", kind: .face, x: 157, y: 92, zone: .right),
        Control(id: "south", kind: .face, x: 125, y: 124, zone: .right),
        Control(id: "minus", kind: .small, x: -46, y: 86, zone: .top),
        Control(id: "home", kind: .home, x: 0, y: 74, zone: .top),
        Control(id: "plus", kind: .small, x: 46, y: 86, zone: .top),
        Control(id: "west", kind: .face, x: 93, y: 92, zone: .top),
        Control(id: "dpad", kind: .dpad, x: -66, y: 166, zone: .bottom),
        Control(id: "capture", kind: .pill, x: 0, y: 116, zone: .bottom),
        Control(id: "rs", kind: .stick, x: 66, y: 166, zone: .bottom),
    ]

    /// Where each control's line ends on the drawing, where its label sits, and the line between them.
    struct Callout {
        let end: CGPoint
        let label: CGPoint
        let alignment: HorizontalAlignment
        let path: [CGPoint]
    }

    static let callouts: [String: Callout] = {
        var result: [String: Callout] = [:]
        let o = origin
        for (zone, side) in [(Zone.left, CGFloat(-1)), (.right, 1)] {
            let column = o.x + side * 318, elbow = o.x + side * 285
            var last: CGFloat = -99
            for control in controls.filter({ $0.zone == zone }).sorted(by: { $0.y < $1.y }) {
                let end: CGPoint
                switch control.kind {
                case .trigger: end = CGPoint(x: o.x + side * 182, y: o.y - 14)
                case .bumper: end = CGPoint(x: o.x + side * 203, y: o.y + 40)
                default: end = CGPoint(x: control.point.x + side * control.radius, y: control.point.y)
                }
                let row = max(end.y - 4, last + 40)
                last = row
                result[control.id] = Callout(end: end, label: CGPoint(x: column, y: row), alignment: side < 0 ? .trailing : .leading,
                                             path: [CGPoint(x: column - side * 6, y: row + 4), CGPoint(x: elbow, y: row + 4), end])
            }
        }
        let tops: [CGFloat] = [330, 420, 510, 600], bottoms: [CGFloat] = [340, 450, 560]
        for (control, x) in zip(controls.filter { $0.zone == .top }.sorted { $0.x < $1.x }, tops) {
            let end = CGPoint(x: control.point.x, y: control.point.y - control.radius)
            result[control.id] = Callout(end: end, label: CGPoint(x: x, y: 34), alignment: .center,
                                         path: [CGPoint(x: x, y: 58), CGPoint(x: x, y: 68), CGPoint(x: end.x, y: o.y - 34), end])
        }
        for (control, x) in zip(controls.filter { $0.zone == .bottom }.sorted { $0.x < $1.x }, bottoms) {
            let end = CGPoint(x: control.point.x, y: control.point.y + control.radius)
            result[control.id] = Callout(end: end, label: CGPoint(x: x, y: 468), alignment: .center,
                                         path: [end, CGPoint(x: end.x, y: 422), CGPoint(x: x, y: 440), CGPoint(x: x, y: 452)])
        }
        return result
    }()

    // MARK: Pad kinds

    private var isNintendo: Bool {
        pad.vendorID == 0x057E || pad.name.localizedCaseInsensitiveContains("pro controller") || pad.name.localizedCaseInsensitiveContains("joy-con")
    }

    /// The button behind each drawn control for this pad: Apple's support names by position, raw HID by number.
    private func button(for id: String) -> PadButton? {
        if let learnt = model.gamepads.position(of: id, for: pad) { return learnt }
        if pad.source == .gameController {
            let names = ["south": "buttonA", "east": "buttonB", "west": "buttonX", "north": "buttonY", "l": "leftShoulder", "r": "rightShoulder",
                         "zl": "leftTrigger", "zr": "rightTrigger", "minus": "buttonOptions", "plus": "buttonMenu",
                         "ls": "leftThumbstickButton", "rs": "rightThumbstickButton"]
            return names[id].map(PadButton.gc)
        }
        // Nintendo in plain HID: 1 B, 2 A, 3 Y, 4 X, 5 L, 6 R, 7 ZL, 8 ZR, 9 −, 10 +, 11 L3, 12 R3, 13 Home, 14 Capture.
        // Most other HID pads: 1 south, 2 east, 3 west, 4 north, then the same order.
        let numbers = ["south": 1, "east": 2, "west": 3, "north": 4, "l": 5, "r": 6, "zl": 7, "zr": 8, "minus": 9, "plus": 10,
                       "ls": 11, "rs": 12, "home": 13, "capture": 14]
        return numbers[id].map(PadButton.hid)
    }

    private func name(of id: String) -> String {
        switch id {
        case "zl": return isNintendo ? "ZL" : "LT"
        case "zr": return isNintendo ? "ZR" : "RT"
        case "l": return isNintendo ? "L" : "LB"
        case "r": return isNintendo ? "R" : "RB"
        case "north": return isNintendo ? "X" : "Y"
        case "east": return isNintendo ? "A" : "B"
        case "south": return isNintendo ? "B" : "A"
        case "west": return isNintendo ? "Y" : "X"
        case "minus": return isNintendo ? "−" : String(localized: "Vista")
        case "plus": return isNintendo ? "+" : String(localized: "Menu")
        case "home": return "Home"
        case "capture": return isNintendo ? String(localized: "Cattura") : String(localized: "Condividi")
        case "ls": return String(localized: "Levetta sinistra")
        case "rs": return String(localized: "Levetta destra")
        case "dpad": return String(localized: "Croce")
        default: return id
        }
    }

    // MARK: Colours

    private var dark: Bool { scheme == .dark }
    private var bodyTop: Color { dark ? Color(white: 0.24) : Color(white: 0.955) }
    private var bodyBottom: Color { dark ? Color(white: 0.15) : Color(white: 0.85) }
    private var edge: Color { dark ? Color(white: 0.35) : Color(white: 0.71) }
    private var keyTop: Color { dark ? Color(white: 0.29) : .white }
    private var keyBottom: Color { dark ? Color(white: 0.2) : Color(white: 0.89) }
    private var well: Color { dark ? Color(white: 0.12) : Color(white: 0.84) }
    private var lead: Color { dark ? Color(white: 0.36) : Color(white: 0.78) }

    // MARK: View

    var body: some View {
        let gamepads = model.gamepads
        let mapping = gamepads.mapping(for: pad)
        GeometryReader { geo in
            let s = geo.size.width / Self.size.width
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.scaleBy(x: s, y: s)
                    drawShell(&context)
                    for control in Self.controls {
                        let button = button(for: control.id)
                        let action = button.flatMap { mapping.action(for: $0) }
                        let lit = button.map { gamepads.lit.contains($0) } ?? false
                        let hot = editing == control.id || lit
                        drawControl(&context, control, assigned: action != nil || control.kind == .dpad, hot: hot, lit: lit)
                        drawCallout(&context, control, assigned: action != nil || control.kind == .dpad, hot: hot)
                    }
                }
                ForEach(Self.controls) { control in
                    hitArea(control, scale: s, mapping: mapping, lit: button(for: control.id).map { gamepads.lit.contains($0) } ?? false)
                }
            }
        }
        .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
    }

    // MARK: Drawing

    private func drawShell(_ context: inout GraphicsContext) {
        let o = Self.origin
        // Triggers peek out behind the bumpers.
        for side in [CGFloat(-1), 1] {
            let rect = CGRect(x: o.x + side * 150 - 32, y: o.y - 26, width: 64, height: 26)
            context.fill(Path(roundedRect: rect, cornerRadius: 10), with: .linearGradient(Gradient(colors: [keyTop, keyBottom]), startPoint: rect.origin, endPoint: CGPoint(x: rect.minX, y: rect.maxY)))
        }
        var bridge = Path()
        bridge.move(to: CGPoint(x: o.x - 96, y: o.y + 10)); bridge.addLine(to: CGPoint(x: o.x + 96, y: o.y + 10))
        context.stroke(bridge, with: .color(edge), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        let shell = Self.shellPath
        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 10))
        shadowed.fill(shell, with: .linearGradient(Gradient(colors: [bodyTop, bodyBottom]), startPoint: CGPoint(x: o.x, y: o.y + 20), endPoint: CGPoint(x: o.x, y: o.y + 294)))
        context.stroke(shell, with: .color(edge), lineWidth: 1.2)
    }

    static let shellPath: Path = {
        let o = origin
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x, y: o.y + y) }
        var path = Path()
        path.move(to: p(0, 42))
        let left: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (-40, 42, -72, 24, -102, 20), (-150, 14, -186, 24, -202, 48), (-224, 82, -240, 150, -247, 210),
            (-253, 256, -238, 292, -205, 293), (-180, 294, -162, 272, -145, 247), (-125, 217, -100, 202, -60, 202),
        ]
        for c in left { path.addCurve(to: p(c.4, c.5), control1: p(c.0, c.1), control2: p(c.2, c.3)) }
        path.addLine(to: p(60, 202))
        let right: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (100, 202, 125, 217, 145, 247), (162, 272, 180, 294, 205, 293), (238, 292, 253, 256, 247, 210),
            (240, 150, 224, 82, 202, 48), (186, 24, 150, 14, 102, 20), (72, 24, 40, 42, 0, 42),
        ]
        for c in right { path.addCurve(to: p(c.4, c.5), control1: p(c.0, c.1), control2: p(c.2, c.3)) }
        path.closeSubpath()
        return path
    }()

    private func drawControl(_ context: inout GraphicsContext, _ control: Control, assigned: Bool, hot: Bool, lit: Bool) {
        let c = control.point
        let accent = Color.accentColor
        let stroke: GraphicsContext.Shading = .color(hot || assigned ? accent : edge)
        let width: CGFloat = hot ? 3 : assigned ? 1.6 : 0.8
        let keyFill: GraphicsContext.Shading = lit ? .color(accent)
            : .linearGradient(Gradient(colors: [keyTop, keyBottom]), startPoint: CGPoint(x: c.x, y: c.y - control.radius), endPoint: CGPoint(x: c.x, y: c.y + control.radius))
        func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
        switch control.kind {
        case .bumper:
            let side: CGFloat = control.x < 0 ? -1 : 1, o = Self.origin
            var path = Path()
            path.move(to: CGPoint(x: o.x + side * 200, y: o.y + 46))
            path.addCurve(to: CGPoint(x: o.x + side * 100, y: o.y + 9), control1: CGPoint(x: o.x + side * 190, y: o.y + 20), control2: CGPoint(x: o.x + side * 156, y: o.y + 6))
            context.stroke(path, with: lit ? .color(accent) : .color(assigned || hot ? accent.opacity(hot ? 1 : 0.45) : (dark ? Color(white: 0.32) : Color(white: 0.82))),
                           style: StrokeStyle(lineWidth: 13, lineCap: .round))
        case .trigger:
            let rect = CGRect(x: c.x - 32, y: c.y - 12, width: 64, height: 26)
            let shape = Path(roundedRect: rect, cornerRadius: 10)
            if lit { context.fill(shape, with: .color(accent)) }
            context.stroke(shape, with: stroke, lineWidth: width)
        case .stick:
            context.fill(circle(31), with: .color(well))
            context.stroke(circle(31), with: .color(edge), lineWidth: 0.8)
            context.fill(circle(21), with: lit ? .color(accent) : .radialGradient(Gradient(colors: [Color(white: dark ? 0.36 : 0.36), Color(white: dark ? 0.11 : 0.17)]), center: CGPoint(x: c.x - 3, y: c.y - 4), startRadius: 0, endRadius: 24))
            context.stroke(circle(21), with: stroke, lineWidth: width)
            context.stroke(circle(14), with: .color(edge.opacity(0.6)), lineWidth: 0.8)
        case .dpad:
            context.fill(circle(33), with: .color(well))
            context.stroke(circle(33), with: .color(edge), lineWidth: 0.8)
            var cross = Path(roundedRect: CGRect(x: c.x - 9, y: c.y - 27, width: 18, height: 54), cornerRadius: 3)
            cross.addPath(Path(roundedRect: CGRect(x: c.x - 27, y: c.y - 9, width: 54, height: 18), cornerRadius: 3))
            context.fill(cross, with: keyFill)
            context.stroke(Path(roundedRect: CGRect(x: c.x - 9, y: c.y - 27, width: 18, height: 54), cornerRadius: 3), with: stroke, lineWidth: width)
            context.stroke(Path(roundedRect: CGRect(x: c.x - 27, y: c.y - 9, width: 54, height: 18), cornerRadius: 3), with: stroke, lineWidth: width)
        case .pill:
            let shape = Path(roundedRect: CGRect(x: c.x - 12, y: c.y - 5, width: 24, height: 10), cornerRadius: 5)
            context.fill(shape, with: keyFill)
            context.stroke(shape, with: stroke, lineWidth: width)
        case .face, .small, .home:
            context.fill(circle(control.radius), with: keyFill)
            context.stroke(circle(control.radius), with: stroke, lineWidth: width)
        }
    }

    private func drawCallout(_ context: inout GraphicsContext, _ control: Control, assigned: Bool, hot: Bool) {
        guard let callout = Self.callouts[control.id] else { return }
        var path = Path()
        path.move(to: callout.path[0])
        for point in callout.path.dropFirst() { path.addLine(to: point) }
        let colour: Color = hot ? .accentColor : assigned ? Color.accentColor.opacity(0.45) : lead
        context.stroke(path, with: .color(colour), lineWidth: hot ? 2 : 1)
        context.fill(Path(ellipseIn: CGRect(x: callout.end.x - 2.6, y: callout.end.y - 2.6, width: 5.2, height: 5.2)), with: .color(colour))
    }

    // MARK: Clicks and labels

    @ViewBuilder
    private func hitArea(_ control: Control, scale s: CGFloat, mapping: ControllerMapping, lit: Bool) -> some View {
        let button = button(for: control.id)
        let action = button.flatMap { mapping.action(for: $0) }
        let hot = editing == control.id || lit
        if let callout = Self.callouts[control.id] {
            let width: CGFloat = 150 * s
            let label = VStack(alignment: callout.alignment, spacing: 1) {
                Text(name(of: control.id)).font(.system(size: max(10, 12.5 * s), weight: .semibold))
                    .foregroundStyle(hot ? Color.accentColor : .primary)
                Text(control.kind == .dpad ? String(localized: "Muoviti") : action.map(padActionName) ?? "—")
                    .font(.system(size: max(9.5, 12 * s), weight: hot ? .semibold : .regular))
                    .foregroundStyle(action != nil || control.kind == .dpad ? Color.accentColor : .secondary)
            }
            .lineLimit(1).fixedSize()
            .frame(width: width, alignment: Alignment(horizontal: callout.alignment, vertical: .top))
            let labelX: CGFloat = callout.alignment == .trailing ? callout.label.x * s - width / 2
                : callout.alignment == .leading ? callout.label.x * s + width / 2 : callout.label.x * s
            if let button, control.kind != .dpad, GamepadNavigator.remappingEnabled {
                Button { editing = control.id } label: { label.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .position(x: labelX, y: (callout.label.y + 6) * s)
                    .popover(isPresented: Binding(get: { editing == control.id }, set: { if !$0 { editing = nil } }), arrowEdge: .bottom) {
                        actionPicker(button: button, current: action)
                    }
                // The control itself is clickable too.
                let r = max(control.radius, control.kind == .trigger || control.kind == .bumper ? 26 : 10)
                Button { editing = control.id } label: { Color.clear.frame(width: r * 2 * s, height: r * 2 * s).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .position(x: (control.kind == .bumper ? Self.origin.x + (control.x < 0 ? -170 : 170) : control.point.x) * s,
                              y: (control.kind == .bumper ? Self.origin.y + 22 : control.point.y) * s)
                    .help(String(localized: "\(padButtonName(button)): clic per scegliere l'azione"))
            } else {
                label.position(x: labelX, y: (callout.label.y + 6) * s)
            }
        }
    }

    private func actionPicker(button: PadButton, current: PadAction?) -> some View {
        let gamepads = model.gamepads
        let control = editing ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            Text(name(of: control)).font(.headline)
            Text(String(localized: "Sul controller: \(padButtonName(button))")).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
            ForEach(PadAction.allCases, id: \.self) { item in
                Button {
                    gamepads.assign(button, to: item, for: pad)
                    editing = nil
                } label: {
                    Label(padActionName(item), systemImage: current == item ? "checkmark.circle.fill" : "circle")
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.vertical, 3)
            }
            Divider().padding(.vertical, 4)
            Button {
                gamepads.clear(button, for: pad)
                editing = nil
            } label: { Label(String(localized: "Nessuna azione"), systemImage: current == nil ? "checkmark.circle.fill" : "circle") }
                .buttonStyle(.plain)
            Label(String(localized: "Premi il tasto sul controller per riconoscerlo."), systemImage: "hand.tap")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 250)
        .onAppear {
            gamepads.capturing = nil
            gamepads.calibrating = (pad.id, control, button)
        }
        .onDisappear { gamepads.calibrating = nil }
    }
}
