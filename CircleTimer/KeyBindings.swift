import AppKit

/// Things the keyboard can do while the timer is focused.
enum TimerAction: String, CaseIterable {
    case startStop, switchMode, enterTime, reset, hide, help
    case preset1, preset2, preset3
    case moveLeft, moveRight, moveUp, moveDown
    case cooler, warmer
}

/// Key bindings for the focused timer. Defaults live here; `keybindings.json` in Tick's Application Support
/// folder overrides them per action. Each value is a key name or a list of key names, e.g.
/// `{ "startStop": ["space", "p"], "reset": "x" }`. Key names: single characters, plus
/// space, return, tab, escape, delete, left, right, up, down. Reloaded automatically when the file changes.
@MainActor
final class KeyBindings {
    static let defaults: [TimerAction: [String]] = [
        .startStop: ["space"], .switchMode: ["return"], .enterTime: ["tab"], .reset: ["r"],
        .hide: ["escape"], .help: ["?"],
        .preset1: ["1"], .preset2: ["2"], .preset3: ["3"],
        .moveLeft: ["left", "h"], .moveDown: ["down", "j"], .moveUp: ["up", "k"], .moveRight: ["right", "l"],
        .cooler: [","], .warmer: ["."],
    ]

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tick/keybindings.json")

    private var actionForKey: [String: TimerAction] = [:]
    private var loadedStamp: Date?

    init() { reloadIfChanged(force: true) }

    func action(for event: NSEvent) -> TimerAction? {
        reloadIfChanged()
        var names: [String] = []
        switch event.keyCode {
        case 49: names.append("space")
        case 36, 76: names.append("return")
        case 48: names.append("tab")
        case 53: names.append("escape")
        case 51, 117: names.append("delete")
        case 123: names.append("left")
        case 124: names.append("right")
        case 125: names.append("down")
        case 126: names.append("up")
        default: break
        }
        // Both spellings, so "?" and "/" (or "<" and ",") work whichever way the layout reports Shift.
        for text in [event.charactersIgnoringModifiers, event.characters] {
            if let text, text.count == 1 { names.append(text.lowercased()) }
        }
        return names.lazy.compactMap { self.actionForKey[$0] }.first
    }

    /// Writes the default bindings to the file if it does not exist yet, so there is something to edit.
    static func createFileIfNeeded() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let table = Dictionary(uniqueKeysWithValues: defaults.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONSerialization.data(withJSONObject: table, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private func reloadIfChanged(force: Bool = false) {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Self.url.path)[.modificationDate]) as? Date
        guard force || stamp != loadedStamp else { return }
        loadedStamp = stamp
        var bindings = Self.defaults
        if let data = try? Data(contentsOf: Self.url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (name, value) in object {
                guard let action = TimerAction(rawValue: name) else { continue }
                let keys = (value as? [String]) ?? (value as? String).map { [$0] }
                if let keys, !keys.isEmpty { bindings[action] = keys.map { $0.lowercased() } }
            }
        }
        actionForKey = [:]
        // Earlier actions win when two share a key; the order is fixed so the result is stable.
        for action in TimerAction.allCases.reversed() {
            for key in bindings[action] ?? [] { actionForKey[key] = action }
        }
    }
}
