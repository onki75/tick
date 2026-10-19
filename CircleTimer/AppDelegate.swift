import AppKit
import Combine
import Network
import ApplicationServices
import SwiftUI

final class FloatingTimerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Called after a click that did not move the window; the flag says whether the panel was already key.
    var onClick: ((Bool) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown else { return super.sendEvent(event) }
        let wasKey = isKeyWindow
        let origin = frame.origin
        // The window drag (isMovableByWindowBackground) is tracked inside super until mouse-up.
        super.sendEvent(event)
        if frame.origin == origin { onClick?(wasKey) }
    }
}

/// Site names from the user's blocklist.txt (lowercased, comments removed).
private func blockedDomains() -> [String] { Blocklist.load() }

extension Notification.Name {
    static let tickTabsReplaced = Notification.Name("tickTabsReplaced")
}

/// A tab Tick replaced with the "focus" page, remembered so it can be put back.
private struct ReplacedTab: Codable {
    let app: String      // "chrome" or "safari"
    let window: Int
    let tab: Int
    let url: String
}

private let replacedTabsFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Tick/replaced-tabs.json")

/// Tiny local web server (127.0.0.1 only) that serves the all-black "focus" page,
/// so the address bar shows a short name instead of a long data: address.
private final class FocusPageServer: @unchecked Sendable {
    static let port: UInt16 = 49717
    static let page = """
    <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="dark">
    <meta name="theme-color" content="#000000"><title>Tick</title>
    <style>html,body{height:100%;margin:0;background:#000}</style>
    """

    private var listener: NWListener?
    private let lock = NSLock()
    private var ready = false
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let port = NWEndpoint.Port(rawValue: Self.port),
              let listener = try? NWListener(using: parameters, on: port) else { return }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.lock.lock(); self.ready = (state == .ready); self.lock.unlock()
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let isFavicon = request.hasPrefix("GET /favicon")
                let body = isFavicon ? "" : FocusPageServer.page
                let status = isFavicon ? "204 No Content" : "200 OK"
                let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: (head + body).data(using: .utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        self.listener = listener
    }
}

private let focusServer = FocusPageServer()
private let focusHost = "http://tick.localhost:\(FocusPageServer.port)/"

/// The address the replaced tabs navigate to: the local server, or an all-black data: page as a fallback.
private var focusPageURL: String {
    if focusServer.isReady { return focusHost }
    let html = "<meta charset=utf-8><title>Tick</title><body style=\"margin:0;background:#000\">"
    return "data:text/html;charset=utf-8," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
}

private func appleScriptString(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private let tabScriptHelpers = """
on hostOf(u)
    set AppleScript's text item delimiters to "/"
    try
        set h to text item 3 of u
    on error
        set h to ""
    end try
    set AppleScript's text item delimiters to ""
    return h
end hostOf
on isBlocked(h, domains)
    repeat with d in domains
        set d to d as text
        if h is d or h ends with ("." & d) then return true
    end repeat
    return false
end isBlocked
"""

/// All NSAppleScript work runs on this one serial queue, never on the main thread, so a busy
/// or hung browser can never freeze the timer's UI or key handling.
private let appleScriptQueue = DispatchQueue(label: "tick.applescript")

private func isRunning(_ bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
}

/// Replaces open tabs of blocked sites in Chrome and Safari with a "focus" page, which ends the
/// page and its already open connections at once, and remembers the original addresses.
/// Only browsers that are already running are touched. macOS asks for permission the first time.
/// Runs on `appleScriptQueue`; only its UI effects are dispatched back to the main thread.
private func replaceBlockedTabs() {
    let domains = blockedDomains()
    guard !domains.isEmpty else { return }
    let list = "{" + domains.map { appleScriptString($0) }.joined(separator: ", ") + "}"
    let page = appleScriptString(focusPageURL)

    let chrome = tabScriptHelpers + """

    set domains to \(list)
    set blockedPage to \(page)
    set out to ""
    with timeout of 5 seconds
    tell application "Google Chrome"
        repeat with w in windows
            set wid to id of w
            repeat with t in tabs of w
                set u to URL of t
                if my isBlocked(my hostOf(u), domains) then
                    set tid to id of t
                    set URL of t to blockedPage
                    set out to out & "chrome|" & wid & "|" & tid & "|" & u & linefeed
                end if
            end repeat
        end repeat
    end tell
    end timeout
    return out
    """
    let safari = tabScriptHelpers + """

    set domains to \(list)
    set blockedPage to \(page)
    set out to ""
    with timeout of 5 seconds
    tell application "Safari"
        repeat with w in windows
            set wid to id of w
            set n to count of tabs of w
            repeat with i from 1 to n
                set u to ""
                try
                    set u to URL of tab i of w
                end try
                if u is not "" and my isBlocked(my hostOf(u), domains) then
                    set URL of tab i of w to blockedPage
                    set out to out & "safari|" & wid & "|" & i & "|" & u & linefeed
                end if
            end repeat
        end repeat
    end tell
    end timeout
    return out
    """

    var records = loadReplacedTabs()
    for (bundleID, source) in [("com.google.Chrome", chrome), ("com.apple.Safari", safari)] where isRunning(bundleID) {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else { continue }
        for line in result.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let window = Int(parts[1]), let tab = Int(parts[2]) else { continue }
            records.append(ReplacedTab(app: String(parts[0]), window: window, tab: tab, url: String(parts[3])))
        }
    }
    saveReplacedTabs(records)
    if !records.isEmpty {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .tickTabsReplaced, object: nil)
        }
    }
}

/// Puts the original pages back into the tabs Tick replaced (only if the tab still shows the focus page).
/// Runs on `appleScriptQueue`.
private func restoreReplacedTabs() {
    let records = loadReplacedTabs()
    guard !records.isEmpty else { return }
    var notRestored: [ReplacedTab] = []
    for record in records {
        let bundleID = record.app == "chrome" ? "com.google.Chrome" : "com.apple.Safari"
        guard isRunning(bundleID) else { notRestored.append(record); continue }
        let url = appleScriptString(record.url)
        let source: String
        if record.app == "chrome" {
            source = """
            try
                with timeout of 5 seconds
                tell application "Google Chrome"
                    set t to tab id \(record.tab) of window id \(record.window)
                    set cur to URL of t
                    if cur starts with "data:text/html" or cur starts with "\(focusHost)" then set URL of t to \(url)
                end tell
                end timeout
            end try
            """
        } else {
            source = """
            try
                with timeout of 5 seconds
                tell application "Safari"
                    set t to tab \(record.tab) of window id \(record.window)
                    set cur to URL of t
                    if cur starts with "data:text/html" or cur starts with "\(focusHost)" then set URL of t to \(url)
                end tell
                end timeout
            end try
            """
        }
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
    saveReplacedTabs(notRestored)
}

/// Synchronous restore used on quit: waits on `appleScriptQueue` so the original pages are put
/// back before the process exits (an async block might never get to run).
private func restoreReplacedTabsAndWait() {
    appleScriptQueue.sync { restoreReplacedTabs() }
}

private func loadReplacedTabs() -> [ReplacedTab] {
    guard let data = try? Data(contentsOf: replacedTabsFile) else { return [] }
    return (try? JSONDecoder().decode([ReplacedTab].self, from: data)) ?? []
}

private func saveReplacedTabs(_ records: [ReplacedTab]) {
    if records.isEmpty {
        try? FileManager.default.removeItem(at: replacedTabsFile)
    } else if let data = try? JSONEncoder().encode(records) {
        try? data.write(to: replacedTabsFile)
    }
}

/// Whether the frontmost browser is showing the black focus page in its active tab.
/// `frontBundleID` is read from the frontmost app on the main thread and passed in.
/// Returns nil when no browser is in front (for example while Tick itself is key), meaning "no change".
private func focusPageIsFrontmost(frontBundleID: String?) -> Bool? {
    guard let bundleID = frontBundleID else { return nil }
    let source: String
    switch bundleID {
    case "com.google.Chrome":
        source = """
        with timeout of 5 seconds
        tell application "Google Chrome"
            if (count of windows) > 0 then return URL of active tab of front window
        end tell
        end timeout
        return ""
        """
    case "com.apple.Safari":
        source = """
        with timeout of 5 seconds
        tell application "Safari"
            if (count of windows) > 0 then return URL of current tab of front window
        end tell
        end timeout
        return ""
        """
    case Bundle.main.bundleIdentifier ?? "":
        return nil
    default:
        return false
    }
    var error: NSDictionary?
    let url = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
    return url.hasPrefix(focusHost) || url.hasPrefix("data:text/html")
}

/// Asks the root helper (installed separately) to add or remove the site block in /etc/hosts.
/// Does nothing when the helper is not installed.
enum SiteBlocker {
    private static let helper = "/usr/local/libexec/tick-hosts"
    private static let queue = DispatchQueue(label: "tick.siteblocker")

    static func set(_ on: Bool, wait: Bool = false) {
        guard FileManager.default.isExecutableFile(atPath: helper) else { return }
        let work = {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", helper, on ? "block" : "unblock"]
            process.standardOutput = nil
            process.standardError = nil
            try? process.run()
            process.waitUntilExit()
            // Block on: swap the open tabs of blocked sites for the focus page.
            // Block off: put the original pages back. AppleScript runs off the main thread;
            // on quit the caller restores synchronously (see applicationWillTerminate).
            if process.terminationStatus == 0, !wait {
                appleScriptQueue.async { on ? replaceBlockedTabs() : restoreReplacedTabs() }
            }
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = TimerModel()
    private var panel: FloatingTimerPanel!
    private var presetsWindow: NSWindow?
    private var localKeysMonitor: Any?
    private var optionMonitor: OptionDoubleTapMonitor?
    private var previousApp: NSRunningApplication?
    private var cancellables = Set<AnyCancellable>()
    private var focusPoll: Timer?
    private var focusProbeInFlight = false
    private var homeOrigin: NSPoint?
    private let keyBindings = KeyBindings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configurePanel()

        model.onModeChange = { [weak self] in self?.resizePanelForMode() }

        // Keyboard commands operate only while the timer panel is focused.
        localKeysMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
        optionMonitor = OptionDoubleTapMonitor { [weak self] in
            self?.optionDoubleTapped()
        }
        trackPreviousApp()
        // Option x2 is global and needs Accessibility; ask for it right away instead of failing silently.
        if !AXIsProcessTrusted() { openAccessibilityPermission() }
        // Move the timer as soon as the tabs were swapped, and whenever another app comes to the front.
        NotificationCenter.default.addObserver(forName: .tickTabsReplaced, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.focusPoll != nil { self?.moveTimerToCenter() } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTimerPlace() }
        }
        focusServer.start()
        // Block distracting sites while the timer is running or paused (also clears a stale block at launch).
        // objectWillChange fires before the change lands, so look at the model once the change is complete.
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .map { [weak self] in self?.model.blocksSites ?? false }
            .prepend(false)
            .removeDuplicates()
            .sink { [weak self] active in
                SiteBlocker.set(active)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.setFocusPolling(active) } }
            }
            .store(in: &cancellables)
        // No menu bar item: Option x2 shows the timer, Cmd+Q quits, Cmd+, opens the preset settings.
        showPanel() // First launch: the app is immediately discoverable.
    }

    /// Opening Tick again while it is running shows the timer. It needs no permission, so it still works
    /// when Option x2 does not (for example after a reinstall reset the accessibility permission).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        SiteBlocker.set(false, wait: true) // unblock first, waiting for the helper to finish
        restoreReplacedTabsAndWait()       // then put the original pages back before the process exits
        if let localKeysMonitor { NSEvent.removeMonitor(localKeysMonitor) }
        optionMonitor?.stop()
    }

    private func configurePanel() {
        panel = FloatingTimerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 222, height: 222),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: TimerFaceView(model: model))
        panel.onClick = { [weak self] wasKey in
            MainActor.assumeIsolated { self?.handlePanelClick(wasKey: wasKey) }
        }
        if let screen = NSScreen.screens.first {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2,
                                         y: f.midY - panel.frame.height / 2))
        }
        let nc = NotificationCenter.default
        // Drop stale pixels of the transparent window while it is being dragged.
        nc.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.invalidateShadow()
                self?.panel.contentView?.needsDisplay = true
            }
        }
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.isFocused = NSApp.isActive // focused only while the app is active too
                self?.model.stopAlarm() // focusing the timer silences the alarm and resets it
            }
        }
        nc.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.isFocused = false
                self?.model.showHelp = false
            }
        }
        // The app becoming active/inactive also decides whether the panel counts as focused.
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.isFocused = self.panel.isKeyWindow
            }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.isFocused = false
                self?.model.showHelp = false
            }
        }
    }

    private func resizePanelForMode() {
        guard let panel else { return }
        let newSize = model.mode == .timer
            ? NSSize(width: 222, height: 222)
            : NSSize(width: 245, height: 105)
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let origin = NSPoint(x: center.x - newSize.width / 2,
                             y: center.y - newSize.height / 2)
        panel.setFrame(NSRect(origin: origin, size: newSize), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Remembers the last frontmost app other than Tick so focus can be handed back to it.
    private func trackPreviousApp() {
        let ownID = Bundle.main.bundleIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != ownID {
            previousApp = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != ownID else { return }
            MainActor.assumeIsolated { self?.previousApp = app }
        }
    }

    /// Arrow keys nudge the window; Shift + arrow snaps it to that edge of the screen.
    private func movePanel(_ direction: (dx: CGFloat, dy: CGFloat), toEdge: Bool) {
        guard let area = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var origin = panel.frame.origin
        let size = panel.frame.size
        if toEdge {
            if direction.dx < 0 { origin.x = area.minX }
            if direction.dx > 0 { origin.x = area.maxX - size.width }
            if direction.dy < 0 { origin.y = area.minY }
            if direction.dy > 0 { origin.y = area.maxY - size.height }
        } else {
            let step: CGFloat = 24
            origin.x += direction.dx * step
            origin.y += direction.dy * step
        }
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: toEdge)
    }

    /// Click on the timer: focus it (done by the window system). Clicking again while focused starts or stops
    /// the timer and hands focus back.
    private func handlePanelClick(wasKey: Bool) {
        if !wasKey { NSApp.activate(ignoringOtherApps: true) } // a click on the unfocused panel also brings the app forward
        if model.isAlarming { model.stopAlarm(); return } // first click only silences the alarm
        guard wasKey, !model.isEditing else { return }
        // A click on the focused timer toggles it (start / stop) and hands focus back.
        model.toggleRunning()
        returnFocusToPreviousApp()
    }

    /// While the block is active, put the timer in the middle of the screen whenever the black page is
    /// in front, and back at its own place when that page is closed or another page is shown.
    private func setFocusPolling(_ active: Bool) {
        focusPoll?.invalidate()
        focusPoll = nil
        guard active else { moveTimerHome(); return }
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateTimerPlace() }
        }
        // .common so the probe keeps ticking while the window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        focusPoll = timer
    }

    /// Probes the frontmost browser off the main thread, one probe at a time: while a probe is
    /// still running the later ticks are skipped, so they never pile up on a busy browser.
    private func updateTimerPlace() {
        guard focusPoll != nil, !focusProbeInFlight else { return }
        focusProbeInFlight = true
        let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        appleScriptQueue.async {
            let onPage = focusPageIsFrontmost(frontBundleID: frontBundleID)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.focusProbeInFlight = false
                    guard self.focusPoll != nil else { return }
                    self.applyTimerPlace(onPage)
                }
            }
        }
    }

    private func applyTimerPlace(_ onPage: Bool?) {
        guard let onPage else { return }
        onPage ? moveTimerToCenter() : moveTimerHome()
    }

    private func moveTimerToCenter() {
        guard panel.isVisible, let screen = panel.screen ?? NSScreen.main else { return }
        if homeOrigin == nil { homeOrigin = panel.frame.origin }
        let size = panel.frame.size
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
        guard panel.frame.origin != origin else { return }
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
    }

    private func moveTimerHome() {
        guard let home = homeOrigin else { return }
        homeOrigin = nil
        panel.setFrame(NSRect(origin: home, size: panel.frame.size), display: true, animate: true)
    }

    private func returnFocusToPreviousApp() {
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
        NSApp.deactivate()
    }

    /// Option x2: focus the timer, or hand focus back to the previous app if already focused.
    private func optionDoubleTapped() {
        if panel.isVisible, panel.isKeyWindow, NSApp.isActive {
            returnFocusToPreviousApp()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true) // the app must be active before the panel can become key
        panel.makeKey()
    }

    private func hidePanel() {
        panel.orderOut(nil)
    }

    /// Returns true when the event has been handled by the timer.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard panel.isVisible, panel.isKeyWindow, !event.isARepeat else { return false }

        // While the alarm rings, Space / Return / Esc stop it and reset the timer.
        if model.isAlarming, [49, 36, 76, 53].contains(event.keyCode) {
            model.stopAlarm()
            return true
        }

        // Command shortcuts: close the window (timers keep running) or quit the app.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command {
            switch event.keyCode {
            case 13: hidePanel(); return true // Cmd+W
            case 12: NSApp.terminate(nil); return true // Cmd+Q
            case 43: openPresetSettings(); return true // Cmd+, opens preset settings
            default: return false
            }
        }
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(blockedModifiers).isEmpty else { return false }

        // When editing, number keys must enter numbers rather than trigger presets.
        if model.isEditing {
            switch event.keyCode {
            case 36, 76: model.confirmEditing(); return true // Return and keypad Enter
            case 49: // Space: confirm and start, then hand focus back
                model.confirmEditing(); model.toggleRunning()
                if model.isRunning { returnFocusToPreviousApp() }
                return true
            case 53: return true // Escape: editing cannot be cancelled
            case 51, 117: model.deleteLastDigit(); return true // Delete
            case 48: model.restartEditing(); return true // Tab: start over from scratch
            default:
                if let characters = event.charactersIgnoringModifiers,
                   characters.count == 1, let digit = characters.first,
                   digit.isASCII, digit.isNumber {
                    model.appendDigit(digit)
                    return true
                }
                return false
            }
        }

        guard let action = keyBindings.action(for: event) else { return false }
        let toEdge = event.modifierFlags.contains(.shift) // Shift + move key snaps to the screen edge
        switch action {
        case .help: model.showHelp.toggle()
        case .startStop: // start or pause; after starting, hand focus back
            model.toggleRunning()
            if model.isRunning { returnFocusToPreviousApp() }
        case .hide: hidePanel()
        case .enterTime: model.beginEditing()
        case .switchMode: model.selectMode(model.mode == .timer ? .stopwatch : .timer)
        case .reset: model.reset()
        case .cooler: model.adjustWarmth(by: -0.1) // towards white
        case .warmer: model.adjustWarmth(by: 0.1)
        case .moveLeft: movePanel((-1, 0), toEdge: toEdge)
        case .moveRight: movePanel((1, 0), toEdge: toEdge)
        case .moveDown: movePanel((0, -1), toEdge: toEdge)
        case .moveUp: movePanel((0, 1), toEdge: toEdge)
        case .preset1, .preset2, .preset3:
            // Presets only apply to a stopped timer; otherwise the key is left for other apps.
            guard model.mode == .timer, !model.isRunning else { return false }
            model.choosePreset(action == .preset1 ? 0 : action == .preset2 ? 1 : 2)
        }
        return true
    }

    @objc private func openPresetSettings() {
        if let presetsWindow {
            presetsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Tick の設定"
        window.center()
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: PresetSettingsView(model: model) { [weak window] in
            window?.close()
        })
        hosting.sizingOptions = [] // the window has a fixed size; auto-sizing made AppKit loop on constraints and crash
        window.contentView = hosting
        presetsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // Open System Settings as well: some macOS versions do not open it automatically.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
