import AppKit

/// Things the keyboard can do while the timer is focused.
enum TimerAction: String, CaseIterable {
    case startStop, switchMode, enterTime, reset, hide, help
    case preset1, preset2, preset3
    case moveLeft, moveRight, moveUp, moveDown
    case cooler, warmer
}

/// Key bindings for the focused timer. The defaults live here; changes made in Settings are saved to
/// `keybindings.json` in Tick's Application Support folder as `{ "startStop": ["space", "p"], ... }`
/// (only the actions that differ from the defaults). The file can also be edited by hand and is reloaded
/// when it changes. Key names: single characters, plus space, return, tab, escape, delete, left, right, up, down.
@MainActor
final class KeyBindings: ObservableObject {
    static let shared = KeyBindings()

    static let defaults: [TimerAction: [String]] = [
        .startStop: ["space"], .switchMode: ["return"], .enterTime: ["tab"], .reset: ["r"],
        .hide: ["escape"], .help: ["?"],
        .preset1: ["1"], .preset2: ["2"], .preset3: ["3"],
        .moveLeft: ["left", "h"], .moveDown: ["down", "j"], .moveUp: ["up", "k"], .moveRight: ["right", "l"],
        .cooler: [","], .warmer: ["."],
    ]

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tick/keybindings.json")

    @Published private(set) var bindings = KeyBindings.defaults
    private var actionForKey: [String: TimerAction] = [:]
    private var loadedStamp: Date?

    private init() { reloadIfChanged(force: true) }

    func keys(for action: TimerAction) -> [String] { bindings[action] ?? [] }

    func isDefault(_ action: TimerAction) -> Bool { keys(for: action) == Self.defaults[action] }

    func action(for event: NSEvent) -> TimerAction? {
        reloadIfChanged()
        return Self.names(for: event).lazy.compactMap { self.actionForKey[$0] }.first
    }

    /// Every name the event can be known by. Both spellings of a character are included, so "?" and "/"
    /// (or "<" and ",") work whichever way the layout reports Shift.
    static func names(for event: NSEvent) -> [String] {
        var names: [String] = []
        if let special = specialName(for: event.keyCode) { names.append(special) }
        for text in [event.charactersIgnoringModifiers, event.characters] {
            if let text, text.count == 1 { names.append(text.lowercased()) }
        }
        return names
    }

    /// The one name used when recording a key in Settings; nil for keys that cannot be bound.
    static func recordedName(for event: NSEvent) -> String? {
        if let special = specialName(for: event.keyCode) { return special }
        guard let text = event.charactersIgnoringModifiers, text.count == 1,
              text.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && $0.value >= 0x21 && $0.value < 0xF700 })
        else { return nil }
        return text.lowercased()
    }

    private static func specialName(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 49: return "space"
        case 36, 76: return "return"
        case 48: return "tab"
        case 53: return "escape"
        case 51, 117: return "delete"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: return nil
        }
    }

    /// How a key name is shown in Settings.
    static func display(_ key: String) -> String {
        switch key {
        case "space": return "Space"
        case "return": return "Return"
        case "tab": return "Tab"
        case "escape": return "Esc"
        case "delete": return "Delete"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return key.uppercased()
        }
    }

    /// Makes `key` the only key of `action`. Returns the other action that already uses it, in which case nothing changes.
    func assign(_ key: String, to action: TimerAction) -> TimerAction? {
        if let owner = actionForKey[key], owner != action { return owner }
        bindings[action] = [key]
        rebuildAndSave()
        return nil
    }

    func reset(_ action: TimerAction) {
        // Keys that another action has taken in the meantime stay with that action.
        let free = (Self.defaults[action] ?? []).filter { actionForKey[$0] == nil || actionForKey[$0] == action }
        bindings[action] = free
        rebuildAndSave()
    }

    func resetAll() {
        bindings = Self.defaults
        rebuildAndSave()
    }

    private func rebuildAndSave() {
        rebuildLookup()
        let overrides = Dictionary(uniqueKeysWithValues: bindings
            .filter { $0.value != Self.defaults[$0.key] }
            .map { ($0.key.rawValue, $0.value) })
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: overrides, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.url)
        }
        loadedStamp = (try? FileManager.default.attributesOfItem(atPath: Self.url.path)[.modificationDate]) as? Date
    }

    private func reloadIfChanged(force: Bool = false) {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Self.url.path)[.modificationDate]) as? Date
        guard force || stamp != loadedStamp else { return }
        loadedStamp = stamp
        var loaded = Self.defaults
        if let data = try? Data(contentsOf: Self.url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (name, value) in object {
                guard let action = TimerAction(rawValue: name) else { continue }
                let keys = (value as? [String]) ?? (value as? String).map { [$0] }
                if let keys, !keys.isEmpty { loaded[action] = keys.map { $0.lowercased() } }
            }
        }
        bindings = loaded
        rebuildLookup()
    }

    private func rebuildLookup() {
        actionForKey = [:]
        // Earlier actions win when two share a key; the order is fixed so the result is stable.
        for action in TimerAction.allCases.reversed() {
            for key in bindings[action] ?? [] { actionForKey[key] = action }
        }
    }
}
