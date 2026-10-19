import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class TimerModel: ObservableObject {
    enum Mode {
        case stopwatch
        case timer
    }

    @Published private(set) var mode: Mode = .timer
    @Published private(set) var isRunning = false
    @Published private(set) var stopwatchElapsed: TimeInterval = 0
    @Published private(set) var timerRemaining: TimeInterval = 10 * 60
    @Published private(set) var timerDuration: TimeInterval = 10 * 60
    @Published private(set) var isEditing = false
    @Published var isFocused = false
    @Published var showHelp = false
    /// 0 = white, 1 = warm amber. Adjusted with "," and "." (shown as "<" and ">").
    @Published private(set) var warmth: Double = {
        let v = UserDefaults.standard.object(forKey: "warmth") as? Double ?? 0
        return min(max(v, 0), 1)
    }()
    @Published private(set) var isAlarming = false
    @Published private(set) var editingDigits = ""
    @Published private(set) var presetMinutes: [Int]

    var onUpdate: (() -> Void)?
    var onModeChange: (() -> Void)?

    private var stopwatchStartedAt: Date?
    private var timerDeadline: Date?
    private var ticker: Timer?
    private var alarmTimer: Timer?
    private var alarmRepeats = 0
    private var requestedNotificationPermission = false

    init() {
        let defaults = [10, 30, 60]
        presetMinutes = defaults.indices.map { index in
            let key = "presetMinutes.\(index)"
            let stored = UserDefaults.standard.object(forKey: key) as? Int
            return min(max(stored ?? defaults[index], 1), 5999)
        }
        timerDuration = TimeInterval(presetMinutes[0] * 60)
        timerRemaining = timerDuration

        let ticker = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            // Timer callbacks run on the main run loop.
            Task { @MainActor [weak self] in self?.refreshClock() }
        }
        ticker.tolerance = 0.015
        // .common keeps the clock ticking while a window is dragged or a menu is open.
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    var stopwatchText: String {
        let tenths = max(0, Int((stopwatchElapsed * 10).rounded(.down)))
        let hours = tenths / 36000
        let minutes = (tenths / 600) % 60
        let seconds = (tenths / 10) % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d.%d", hours, minutes, seconds, tenths % 10)
        }
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths % 10)
    }

    var timerText: String {
        Self.formatTimerTime(Int(ceil(max(timerRemaining, 0))))
    }

    var faceText: String {
        if mode == .stopwatch { return stopwatchText }
        if isEditing {
            return Self.formatTimerTime(Self.secondsFromDigits(editingDigits))
        }
        return timerText
    }

    var menuText: String {
        switch mode {
        case .stopwatch:
            let seconds = Int(stopwatchElapsed)
            if seconds >= 3600 {
                return Self.formatTime(seconds)
            }
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        case .timer:
            return timerText
        }
    }

    var progress: Double {
        guard timerDuration > 0 else { return 0 }
        return max(0, min(1, timerRemaining / timerDuration))
    }

    func selectMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        pause()
        isEditing = false
        editingDigits = ""
        mode = newMode
        onModeChange?()
        onUpdate?()
    }

    func toggleRunning() {
        guard !isEditing else { return }
        if isRunning {
            pause()
        } else {
            start()
        }
    }

    private func start() {
        guard !isRunning else { return }
        switch mode {
        case .stopwatch:
            stopwatchStartedAt = Date()
        case .timer:
            if timerRemaining <= 0 { timerRemaining = timerDuration }
            timerDeadline = Date().addingTimeInterval(timerRemaining)
            if !requestedNotificationPermission {
                requestedNotificationPermission = true
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
        isRunning = true
        onUpdate?()
    }

    func pause() {
        guard isRunning else { return }
        refreshClock()
        isRunning = false
        stopwatchStartedAt = nil
        timerDeadline = nil
        onUpdate?()
    }

    func reset() {
        guard !isEditing else { return }
        // Reset also stops a running clock and a ringing alarm.
        stopAlarm()
        pause()
        switch mode {
        case .stopwatch: stopwatchElapsed = 0
        case .timer: timerRemaining = timerDuration
        }
        onUpdate?()
    }

    func choosePreset(_ index: Int) {
        guard mode == .timer, !isRunning, !isEditing,
              presetMinutes.indices.contains(index) else { return }
        timerDuration = TimeInterval(presetMinutes[index] * 60)
        timerRemaining = timerDuration
        onUpdate?()
    }

    func setPresets(_ values: [Int]) {
        guard values.count == 3, values.allSatisfy({ (1...5999).contains($0) }) else { return }
        presetMinutes = values
        for (index, value) in values.enumerated() {
            UserDefaults.standard.set(value, forKey: "presetMinutes.\(index)")
        }
        onUpdate?()
    }

    func beginEditing() {
        guard mode == .timer, !isRunning, !isAlarming else { return }
        editingDigits = ""
        isEditing = true
    }

    func adjustWarmth(by delta: Double) {
        warmth = min(max((warmth + delta).rounded(toPlaces: 1), 0), 1)
        UserDefaults.standard.set(warmth, forKey: "warmth")
    }

    func restartEditing() {
        guard isEditing else { return }
        editingDigits = ""
    }

    func appendDigit(_ digit: Character) {
        guard isEditing, digit.isASCII, digit.isNumber, editingDigits.count < 4 else { return }
        editingDigits.append(digit)
    }

    func deleteLastDigit() {
        guard isEditing, !editingDigits.isEmpty else { return }
        editingDigits.removeLast()
    }

    func cancelEditing() {
        isEditing = false
        editingDigits = ""
    }

    func confirmEditing() {
        guard isEditing else { return }
        let seconds = Self.secondsFromDigits(editingDigits)
        cancelEditing()
        guard seconds > 0 else { return } // Empty input leaves previous duration unchanged.
        timerDuration = TimeInterval(seconds)
        timerRemaining = timerDuration
        onUpdate?()
    }

    private func refreshClock() {
        guard isRunning else { return }
        let now = Date()
        switch mode {
        case .stopwatch:
            if let started = stopwatchStartedAt {
                stopwatchElapsed += max(0, now.timeIntervalSince(started))
                stopwatchStartedAt = now
            }
        case .timer:
            if let deadline = timerDeadline {
                let remaining = deadline.timeIntervalSince(now)
                // Treat an imminent deadline as already done, so resuming just before it
                // cannot leave the timer looking stopped while it still counts down.
                timerRemaining = remaining < 0.05 ? 0 : remaining
                if timerRemaining <= 0 {
                    isRunning = false
                    timerDeadline = nil
                    notifyCompletion()
                }
            }
        }
        onUpdate?()
    }

    private func notifyCompletion() {
        NSSound(named: NSSound.Name("Glass"))?.play()
        let content = UNMutableNotificationContent()
        content.title = "タイマー終了"
        content.body = "設定した時間になりました"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
        startAlarm()
    }

    /// Repeats the chime every 3 seconds (at most 10 times) until stopped.
    private func startAlarm() {
        alarmTimer?.invalidate()
        isAlarming = true
        alarmRepeats = 1
        alarmTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isAlarming else { return }
                self.alarmRepeats += 1
                if self.alarmRepeats > 10 {
                    self.stopAlarm()
                } else {
                    NSSound(named: NSSound.Name("Glass"))?.play()
                }
            }
        }
    }

    /// Stops the alarm and resets the timer to its full duration.
    func stopAlarm() {
        guard isAlarming else { return }
        alarmTimer?.invalidate()
        alarmTimer = nil
        isAlarming = false
        if isEditing { // an alarm that starts while editing cancels the input
            isEditing = false
            editingDigits = ""
        }
        timerRemaining = timerDuration
        onUpdate?()
    }

    static func secondsFromDigits(_ digits: String) -> Int {
        // Four digits at most: "1230" = 12:30, "9999" is rounded to 99:59.
        guard let n = Int(digits), !digits.isEmpty else { return 0 }
        let seconds = min(n % 100, 59)
        let minutes = min((n / 100) % 100, 99)
        return minutes * 60 + seconds
    }

    /// Timer display: mm:ss up to 99:59, h:mm:ss beyond that.
    static func formatTimerTime(_ seconds: Int) -> String {
        let amount = max(0, seconds)
        if amount < 6000 { return String(format: "%02d:%02d", amount / 60, amount % 60) }
        return formatTime(amount)
    }

    static func formatTime(_ seconds: Int) -> String {
        let amount = max(0, seconds)
        if amount >= 3600 {
            return String(format: "%d:%02d:%02d", amount / 3600,
                          (amount / 60) % 60, amount % 60)
        }
        return String(format: "%02d:%02d", amount / 60, amount % 60)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
