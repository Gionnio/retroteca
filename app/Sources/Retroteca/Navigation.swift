import SwiftUI
import AppKit
import Combine
import GameController
import IOKit.hid
import RetrotecaCore

/// What a remote, a controller or the keyboard asks: pages turn these into moves and actions.
enum NavCommand: Equatable {
    case up, down, left, right
    /// A / Return: play, install or open.
    case select
    /// B / Esc.
    case back
    /// Y / Space: details, or the options of a Switch game.
    case secondary
    /// LB / RB: the pill before or after in the top bar.
    case previousPage, nextPage
    /// Menu: full screen on and off.
    case menu
}

/// How Retroteca is driven: everything, or only keyboard and mouse, or only controllers (the pointer hides).
enum InputMode: String, CaseIterable, Identifiable {
    case all, keyboardMouse, controller
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return String(localized: "Tastiera, mouse e controller")
        case .keyboardMouse: return String(localized: "Solo tastiera e mouse")
        case .controller: return String(localized: "Solo controller")
        }
    }
}

/// A pad Retroteca reads, through Apple's controller support or as raw HID (pads macOS pairs but does not list,
/// such as some Nintendo and 8BitDo pads).
struct ConnectedPad: Identifiable, Equatable {
    enum Source: String { case gameController, hid }
    let id: String
    let name: String
    let source: Source
    let vendorID: Int?
    let productID: Int?
    var profileKey: String { ControllerProfiles.key(name: name, vendorID: vendorID, productID: productID) }
    var defaultMapping: ControllerMapping {
        source == .gameController ? .gameController : .hidDefault(vendorID: vendorID ?? 0)
    }
}

/// Controllers connected to the Mac drive the whole app while Retroteca is in front (never while a game is).
@MainActor
final class GamepadNavigator: ObservableObject {
    @Published private(set) var pads: [ConnectedPad] = []
    @Published private(set) var profiles = ControllerProfiles.load(from: .standard)
    /// The last control pressed, to try a pad in the Settings.
    @Published private(set) var lastPressed: (pad: String, button: PadButton)?
    /// Buttons held down right now (briefly lit on the drawn pad in the Settings).
    @Published private(set) var lit: Set<PadButton> = []
    /// While set, the next button pressed on that pad is taken as this drawn control (the Settings' pad drawing).
    @Published var calibrating: (padID: String, control: String, previous: PadButton?)?
    /// While set, the next button pressed on that pad is given to this action instead of acting.
    @Published var capturing: (padID: String, action: PadAction)?

    var send: ((NavCommand) -> Void)?
    var announce: ((String) -> Void)?

    var connected: [String] { pads.map(\.name) }
    var mode: InputMode { InputMode(rawValue: UserDefaults.standard.string(forKey: "inputMode") ?? "") ?? .all }

    private var held: [String: NavCommand] = [:]
    private var repeatTasks: [String: Task<Void, Never>] = [:]
    private var observers: [NSObjectProtocol] = []
    private var hidManager: IOHIDManager?
    private var hidDevices: [String: IOHIDDevice] = [:]
    /// Last x/y of each HID pad's stick and hat, to turn them into moves.
    private var axes: [String: (x: Double, y: Double)] = [:]
    private var hats: [String: (x: Int, y: Int)] = [:]

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self?.attach(controller, announce: true) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshPads() }
        })
        GCController.controllers().forEach { attach($0, announce: false) }
        startHID()
    }

    /// A Pro Controller (057e:2009) that Apple's support does not list, read only as HID. nxnative counts such a pad twice
    /// (two HID devices at one USB location) and reads the pair from report 0x30, which this kind of pad does not send:
    /// a one-player game then keeps asking for controllers and stays black. Its pad-twins switch turns that off.
    var unlistedProController: Bool {
        let listed = GCController.controllers().contains { $0.productCategory == "Switch Pro Controller" }
        guard !listed else { return false }
        return hidDevices.values.contains { device in
            (Self.property(device, kIOHIDVendorIDKey) as? Int) == 0x057E && (Self.property(device, kIOHIDProductIDKey) as? Int) == 0x2009
        }
    }

    func mapping(for pad: ConnectedPad) -> ControllerMapping {
        profiles.mapping(for: pad.profileKey, fallback: pad.defaultMapping)
    }

    func assign(_ button: PadButton, to action: PadAction, for pad: ConnectedPad) {
        var mapping = mapping(for: pad)
        mapping.assign(button, to: action)
        profiles.mappings[pad.profileKey] = mapping
        profiles.save(to: .standard)
    }

    /// The drawn control `control` is this physical button: the action the drawing showed there moves with it.
    func learn(_ button: PadButton, as control: String, for pad: ConnectedPad, previous: PadButton? = nil) {
        if let previous, previous != button, let action = mapping(for: pad).action(for: previous) {
            assign(button, to: action, for: pad)
        }
        var positions = profiles.positions[pad.profileKey] ?? [:]
        for (other, raw) in positions where raw == button.rawValue && other != control { positions[other] = nil }
        positions[control] = button.rawValue
        profiles.positions[pad.profileKey] = positions
        profiles.save(to: .standard)
    }

    func position(of control: String, for pad: ConnectedPad) -> PadButton? {
        profiles.positions[pad.profileKey]?[control].map(PadButton.init(rawValue:))
    }

    /// Takes a button away from its action (it then does nothing in Retroteca).
    func clear(_ button: PadButton, for pad: ConnectedPad) {
        var mapping = mapping(for: pad)
        for (action, bound) in mapping.buttons where bound == button { mapping.buttons[action] = nil }
        profiles.mappings[pad.profileKey] = mapping
        profiles.save(to: .standard)
    }

    func resetMapping(for pad: ConnectedPad) {
        profiles.mappings[pad.profileKey] = nil
        profiles.positions[pad.profileKey] = nil
        profiles.save(to: .standard)
    }

    // MARK: Apple's controller support

    private func refreshPads() {
        let gcPads = GCController.controllers().compactMap { controller -> ConnectedPad? in
            guard controller.extendedGamepad != nil else { return nil }
            return ConnectedPad(id: "gc-\(ObjectIdentifier(controller).hashValue)", name: controller.vendorName ?? "Controller",
                                source: .gameController, vendorID: nil, productID: nil)
        }
        let gcNames = Set(gcPads.map(\.name))
        // A pad Apple's support lists is not read twice through HID.
        let hidPads = hidDevices.compactMap { id, device -> ConnectedPad? in
            let name = Self.property(device, kIOHIDProductKey) as? String ?? "Gamepad"
            guard !gcNames.contains(name) else { return nil }
            return ConnectedPad(id: id, name: name, source: .hid,
                                vendorID: Self.property(device, kIOHIDVendorIDKey) as? Int, productID: Self.property(device, kIOHIDProductIDKey) as? Int)
        }
        pads = (gcPads + hidPads).sorted { $0.name < $1.name }
    }

    private func attach(_ controller: GCController, announce: Bool) {
        guard let pad = controller.extendedGamepad else { return }
        refreshPads()
        if announce { self.announce?(String(localized: "Controller collegato: \(controller.vendorName ?? "Controller").")) }
        let padID = "gc-\(ObjectIdentifier(controller).hashValue)"
        let named: [(String, GCControllerButtonInput)] = [
            ("buttonA", pad.buttonA), ("buttonB", pad.buttonB), ("buttonX", pad.buttonX), ("buttonY", pad.buttonY),
            ("leftShoulder", pad.leftShoulder), ("rightShoulder", pad.rightShoulder),
            ("leftTrigger", pad.leftTrigger), ("rightTrigger", pad.rightTrigger), ("buttonMenu", pad.buttonMenu),
        ] + [("buttonOptions", pad.buttonOptions), ("leftThumbstickButton", pad.leftThumbstickButton),
             ("rightThumbstickButton", pad.rightThumbstickButton)].compactMap { name, input in input.map { (name, $0) } }
        for (name, input) in named {
            input.pressedChangedHandler = { _, _, pressed in
                guard pressed else { return }
                Task { @MainActor [weak self] in self?.pressed(.gc(name), padID: padID) }
            }
        }
        pad.dpad.valueChangedHandler = { _, x, y in Task { @MainActor [weak self] in self?.direction(padID + ".dpad", x: Double(x), y: Double(y)) } }
        pad.leftThumbstick.valueChangedHandler = { _, x, y in Task { @MainActor [weak self] in self?.direction(padID + ".stick", x: Double(x), y: Double(y)) } }
    }

    // MARK: Raw HID

    private func startHID() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = [[kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
                       [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick]] as CFArray
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let navigator = Unmanaged<GamepadNavigator>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { navigator.hidAdded(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let navigator = Unmanaged<GamepadNavigator>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { navigator.hidRemoved(device) }
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let navigator = Unmanaged<GamepadNavigator>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { navigator.hidValue(value) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
    }

    private static func property(_ device: IOHIDDevice, _ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }

    private static func id(of device: IOHIDDevice) -> String { "hid-\(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque().hashValue))" }

    private func hidAdded(_ device: IOHIDDevice) {
        hidDevices[Self.id(of: device)] = device
        let before = Set(pads.map(\.id))
        refreshPads()
        if let pad = pads.first(where: { $0.id == Self.id(of: device) }), !before.contains(pad.id) {
            announce?(String(localized: "Controller collegato: \(pad.name)."))
        }
    }

    private func hidRemoved(_ device: IOHIDDevice) {
        hidDevices[Self.id(of: device)] = nil
        refreshPads()
    }

    private func hidValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let padID = Self.id(of: device)
        // Pads Apple's support already reads are left to it.
        guard pads.contains(where: { $0.id == padID }) else { return }
        let page = Int(IOHIDElementGetUsagePage(element)), usage = Int(IOHIDElementGetUsage(element))
        let raw = IOHIDValueGetIntegerValue(value)
        let minimum = IOHIDElementGetLogicalMin(element), maximum = IOHIDElementGetLogicalMax(element)
        if page == kHIDPage_Button {
            if raw != 0 { pressed(.hid(usage), padID: padID) }
        } else if page == kHIDPage_GenericDesktop {
            switch usage {
            case kHIDUsage_GD_Hatswitch:
                let v = HatDirection.vector(raw, min: minimum, max: maximum)
                hats[padID] = v
                direction(padID + ".hat", x: Double(v.x), y: Double(v.y))
            case kHIDUsage_GD_X, kHIDUsage_GD_Y:
                var stick = axes[padID] ?? (0, 0)
                let n = HatDirection.normalize(raw, min: minimum, max: maximum)
                // HID's Y grows downwards.
                if usage == kHIDUsage_GD_X { stick.x = n } else { stick.y = -n }
                axes[padID] = stick
                direction(padID + ".stick", x: stick.x, y: stick.y)
            default: break
            }
        }
    }

    // MARK: Actions

    private func pressed(_ button: PadButton, padID: String) {
        guard let pad = pads.first(where: { $0.id == padID }) else { return }
        lastPressed = (pad.name, button)
        lit.insert(button)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.lit.remove(button)
        }
        if let capture = capturing, capture.padID == padID {
            assign(button, to: capture.action, for: pad)
            capturing = nil
            return
        }
        if let calibration = calibrating, calibration.padID == padID {
            learn(button, as: calibration.control, for: pad, previous: calibration.previous)
            calibrating = (padID, calibration.control, button)
            return
        }
        guard let action = mapping(for: pad).action(for: button) else { return }
        let command: NavCommand
        switch action {
        case .select: command = .select
        case .back: command = .back
        case .secondary: command = .secondary
        case .previousPage: command = .previousPage
        case .nextPage: command = .nextPage
        case .menu: command = .menu
        }
        fire(command)
    }

    private func fire(_ command: NavCommand) {
        guard mode != .keyboardMouse, NSApp.isActive, capturing == nil else { return }
        if mode == .controller { NSCursor.setHiddenUntilMouseMoves(true) }
        send?(command)
    }

    /// A held direction moves once, then repeats like a key after a short wait.
    private func direction(_ source: String, x: Double, y: Double) {
        let threshold = 0.5
        let command: NavCommand? = abs(x) > abs(y)
            ? (x > threshold ? .right : x < -threshold ? .left : nil)
            : (y > threshold ? .up : y < -threshold ? .down : nil)
        guard command != held[source] else { return }
        held[source] = command
        repeatTasks[source]?.cancel()
        guard let command else { return }
        fire(command)
        repeatTasks[source] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            while !Task.isCancelled, self?.held[source] == command {
                self?.fire(command)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }
}

/// How a control is called on screen.
func padButtonName(_ button: PadButton) -> String {
    if let number = button.hidNumber { return String(localized: "Pulsante \(number)") }
    switch button.rawValue {
    case "gc.buttonA": return "A"
    case "gc.buttonB": return "B"
    case "gc.buttonX": return "X"
    case "gc.buttonY": return "Y"
    case "gc.leftShoulder": return "LB / L"
    case "gc.rightShoulder": return "RB / R"
    case "gc.leftTrigger": return "LT / ZL"
    case "gc.rightTrigger": return "RT / ZR"
    case "gc.buttonMenu": return "Menu / +"
    case "gc.buttonOptions": return "Opzioni / −"
    case "gc.leftThumbstickButton": return String(localized: "Levetta sinistra")
    case "gc.rightThumbstickButton": return String(localized: "Levetta destra")
    default: return button.rawValue
    }
}

func padActionName(_ action: PadAction) -> String {
    switch action {
    case .select: return String(localized: "Scegli e gioca")
    case .back: return String(localized: "Indietro")
    case .secondary: return String(localized: "Dettagli e opzioni")
    case .previousPage: return String(localized: "Sezione precedente")
    case .nextPage: return String(localized: "Sezione successiva")
    case .menu: return String(localized: "Schermo intero")
    }
}

// MARK: - Grids

/// Arrow keys and controller moves over a grid of tiles: the chosen tile lifts, A or Return opens it.
struct GridNavigation: ViewModifier {
    @EnvironmentObject var model: AppModel
    let count: Int
    let columns: Int
    @Binding var focus: Int?
    let open: (Int) -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear { focused = true }
            .onKeyPress(.leftArrow) { handle(.left) }
            .onKeyPress(.rightArrow) { handle(.right) }
            .onKeyPress(.upArrow) { handle(.up) }
            .onKeyPress(.downArrow) { handle(.down) }
            .onKeyPress(.return) { handle(.select) }
            .onReceive(model.navigation) { command in _ = handle(command) }
    }

    private func handle(_ command: NavCommand) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        let current = focus ?? -1
        switch command {
        case .left: focus = max(current - 1, 0)
        case .right: focus = min(current + 1, count - 1)
        case .up: focus = current < 0 ? 0 : max(current - max(columns, 1), 0)
        case .down: focus = current < 0 ? 0 : min(current + max(columns, 1), count - 1)
        case .select:
            guard current >= 0 else { focus = 0; return .handled }
            open(current)
        default: return .ignored
        }
        return .handled
    }
}

extension View {
    func gridNavigation(count: Int, columns: Int, focus: Binding<Int?>, open: @escaping (Int) -> Void) -> some View {
        modifier(GridNavigation(count: count, columns: columns, focus: focus, open: open))
    }

}

/// How many columns an adaptive grid shows at a width.
func adaptiveColumns(width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
    max(1, Int((width + spacing) / (minimum + spacing)))
}
