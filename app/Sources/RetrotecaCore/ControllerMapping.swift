import Foundation

/// What a controller button does in Retroteca's menus. Moves come from the d-pad and the left stick.
public enum PadAction: String, Codable, CaseIterable, Sendable {
    case select, back, secondary, previousPage, nextPage, menu
}

/// One physical control of a pad: from Apple's controller support ("gc.buttonA") or read as raw HID ("hid.3").
public struct PadButton: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static func gc(_ name: String) -> PadButton { PadButton(rawValue: "gc.\(name)") }
    public static func hid(_ number: Int) -> PadButton { PadButton(rawValue: "hid.\(number)") }

    public var hidNumber: Int? { rawValue.hasPrefix("hid.") ? Int(rawValue.dropFirst(4)) : nil }
}

/// How one pad's buttons map to actions, saved per pad (by its name and USB IDs).
public struct ControllerMapping: Codable, Equatable, Sendable {
    public var buttons: [PadAction: PadButton]

    public init(buttons: [PadAction: PadButton]) { self.buttons = buttons }

    public func action(for button: PadButton) -> PadAction? {
        buttons.first { $0.value == button }?.key
    }

    /// Gives `button` to `action`; an action that had it before loses it (one button, one action).
    public mutating func assign(_ button: PadButton, to action: PadAction) {
        for (other, bound) in buttons where bound == button && other != action { buttons[other] = nil }
        buttons[action] = button
    }

    /// Apple's controller support names buttons by position: A confirms, B goes back, Y is the top one.
    public static let gameController = ControllerMapping(buttons: [
        .select: .gc("buttonA"), .back: .gc("buttonB"), .secondary: .gc("buttonY"),
        .previousPage: .gc("leftShoulder"), .nextPage: .gc("rightShoulder"), .menu: .gc("buttonMenu"),
    ])

    /// Raw HID pads number their buttons their own way. Nintendo's Pro Controller in plain HID mode:
    /// 1 B, 2 A, 3 Y, 4 X, 5 L, 6 R, 7 ZL, 8 ZR, 9 −, 10 +; Nintendo confirms with A and goes back with B.
    public static func hidDefault(vendorID: Int) -> ControllerMapping {
        if vendorID == 0x057E {
            return ControllerMapping(buttons: [.select: .hid(2), .back: .hid(1), .secondary: .hid(4),
                                               .previousPage: .hid(5), .nextPage: .hid(6), .menu: .hid(10)])
        }
        // Common for other pads (8BitDo, generic): 1 south, 2 east, 4 north, 5–6 shoulders, 10 start.
        return ControllerMapping(buttons: [.select: .hid(1), .back: .hid(2), .secondary: .hid(4),
                                           .previousPage: .hid(5), .nextPage: .hid(6), .menu: .hid(10)])
    }
}

/// The saved mappings, one per pad: "Pro Controller 057E:2009" → mapping.
public struct ControllerProfiles: Codable, Equatable, Sendable {
    public var mappings: [String: ControllerMapping] = [:]
    /// Per pad, the physical button behind each drawn control, learnt by pressing it ("east" → "hid.2").
    public var positions: [String: [String: String]] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mappings = try container.decodeIfPresent([String: ControllerMapping].self, forKey: .mappings) ?? [:]
        positions = try container.decodeIfPresent([String: [String: String]].self, forKey: .positions) ?? [:]
    }

    public static func key(name: String, vendorID: Int?, productID: Int?) -> String {
        guard let vendorID, let productID else { return name }
        return "\(name) " + String(format: "%04X:%04X", vendorID, productID)
    }

    public func mapping(for key: String, fallback: ControllerMapping) -> ControllerMapping {
        mappings[key] ?? fallback
    }

    public static func load(from defaults: UserDefaults, key: String = "controllerProfiles") -> ControllerProfiles {
        guard let data = defaults.data(forKey: key), let profiles = try? JSONDecoder().decode(ControllerProfiles.self, from: data) else { return ControllerProfiles() }
        return profiles
    }

    public func save(to defaults: UserDefaults, key: String = "controllerProfiles") {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}

/// HID hat switch (d-pad): 0 = up, clockwise in eighths; anything else = centred.
public enum HatDirection {
    public static func vector(_ value: Int, min: Int = 0, max: Int = 7) -> (x: Int, y: Int) {
        guard value >= min, value <= max else { return (0, 0) }
        let steps = max - min + 1
        let eighth = steps == 8 ? value - min : (value - min) * 2
        let table: [(Int, Int)] = [(0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1), (-1, 0), (-1, 1)]
        return table[eighth % 8]
    }

    /// An analog axis value as −1…1 from its logical range.
    public static func normalize(_ value: Int, min: Int, max: Int) -> Double {
        guard max > min else { return 0 }
        return (Double(value - min) / Double(max - min)) * 2 - 1
    }
}
