import AppKit

/// Detects two *standalone* Option-key taps. It does not intercept keystrokes.
/// Global key event monitoring requires macOS Accessibility permission.
@MainActor
final class OptionDoubleTapMonitor {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var isOptionDown = false
    private var optionPressStartedAt: TimeInterval?
    private var lastStandaloneTapAt: TimeInterval?
    private let onDoubleTap: () -> Void

    init(onDoubleTap: @escaping () -> Void) {
        self.onDoubleTap = onDoubleTap
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            // This monitor is non-consuming: normal typing is not affected.
            self?.receive(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.receive(event)
        }
    }

    private func receive(_ event: NSEvent) {
        if event.type == .keyDown {
            // Option+letter is not considered an Option tap.
            lastStandaloneTapAt = nil
            optionPressStartedAt = nil
            return
        }
        guard event.type == .flagsChanged else { return }
        guard event.keyCode == 58 || event.keyCode == 61 else {
            // Pressing other modifier keys cancels a partial double tap.
            lastStandaloneTapAt = nil
            return
        }

        let down = event.modifierFlags.contains(.option)
        let otherModifiers: NSEvent.ModifierFlags = [.command, .control, .shift]
        let standalone = event.modifierFlags.intersection(otherModifiers).isEmpty
        if down && !isOptionDown {
            optionPressStartedAt = standalone ? event.timestamp : nil
        } else if !down && isOptionDown {
            if let began = optionPressStartedAt,
               standalone, event.timestamp - began <= 0.5 {
                if let previous = lastStandaloneTapAt,
                   event.timestamp - previous <= 0.45 {
                    lastStandaloneTapAt = nil
                    onDoubleTap()
                } else {
                    lastStandaloneTapAt = event.timestamp
                }
            } else {
                lastStandaloneTapAt = nil
            }
            optionPressStartedAt = nil
        }
        isOptionDown = down
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }
}
