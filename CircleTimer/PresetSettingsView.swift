import SwiftUI

/// The user's site list (blocklist.txt), shared with the hosts helper. Sites can only be added here.
enum Blocklist {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tick/blocklist.txt")

    static func load() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        return text.split(separator: "\n").compactMap { raw in
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let name = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard name.range(of: "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", options: .regularExpression) != nil,
                  seen.insert(name).inserted else { return nil }
            return name
        }
    }

    /// Reduces a typed or pasted address ("https://www.Example.com/path") to a host name, or nil if it isn't one.
    static func normalized(_ input: String) -> String? {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        host = String(host.prefix { !"/?#:".contains($0) })
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard host.contains("."),
              host.range(of: "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", options: .regularExpression) != nil else { return nil }
        return host
    }

    /// Appends a site. Returns false if it was already listed or could not be written.
    @discardableResult
    static func add(_ host: String) -> Bool {
        guard !load().contains(host) else { return false }
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += host + "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
    }
}

struct PresetSettingsView: View {
    @ObservedObject var model: TimerModel
    var close: () -> Void

    var body: some View {
        TabView {
            GeneralSettingsTab(model: model, close: close)
                .tabItem { Text("一般") }
            KeyBindingsTab(keys: .shared, close: close)
                .tabItem { Text("キー操作") }
        }
        .padding(12)
        .frame(width: 420, height: 680)
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var model: TimerModel
    @State private var values: [String] = ["", "", ""]
    @State private var newSite = ""
    @State private var sites: [String] = []
    @State private var siteMessage: String?
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("タイマープリセット")
                .font(.title2.weight(.semibold))
            Text("タイマーが停止中に、数字キー1〜3で選択できます。")
                .foregroundStyle(.secondary)

            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .frame(width: 24)
                    TextField("分数", text: $values[index])
                        .frame(width: 98)
                    Text("分")
                    Spacer()
                }
            }
            Divider()
            Text("ブロックするサイト")
                .font(.title3.weight(.semibold))
            Text("タイマー動作中に開けなくなります。追加したサイトは次の開始から有効です。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("example.com", text: $newSite)
                    .onSubmit(addSite)
                Button("追加", action: addSite)
                    .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let siteMessage {
                Text(siteMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(sites, id: \.self) { site in
                        Text(site).font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 74)
            Divider()
            HStack {
                Text("1〜5999分で指定")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard let minutes = parsedValues else { return }
                    model.setPresets(minutes)
                    close()
                }
                .buttonStyle(.borderedProminent)
                .disabled(parsedValues == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            values = model.presetMinutes.map(String.init)
            sites = Blocklist.load()
        }
    }

    private func addSite() {
        guard let host = Blocklist.normalized(newSite) else {
            siteMessage = "サイト名を入力してください(例: example.com)"
            return
        }
        if sites.contains(host) {
            siteMessage = "\(host) は追加済みです"
        } else if Blocklist.add(host) {
            sites = Blocklist.load()
            siteMessage = "\(host) を追加しました"
            newSite = ""
        } else {
            siteMessage = "保存できませんでした"
        }
    }

    private var parsedValues: [Int]? {
        let result = values.compactMap(Int.init)
        guard result.count == 3, result.allSatisfy({ (1...5999).contains($0) }) else {
            return nil
        }
        return result
    }
}

/// Lets the user rebind the timer's keys: pick an action, press the new key.
private struct KeyBindingsTab: View {
    @ObservedObject var keys: KeyBindings
    var close: () -> Void
    @State private var recording: TimerAction?
    @State private var monitor: Any?
    @State private var message: String?

    private static let labels: [(TimerAction, String)] = [
        (.startStop, "開始 / 停止"), (.switchMode, "タイマー / ストップウォッチ"), (.enterTime, "時間を入力"),
        (.reset, "リセット"), (.hide, "タイマーを隠す"), (.help, "ヒントの表示"),
        (.preset1, "プリセット 1"), (.preset2, "プリセット 2"), (.preset3, "プリセット 3"),
        (.moveLeft, "左へ移動"), (.moveRight, "右へ移動"), (.moveUp, "上へ移動"), (.moveDown, "下へ移動"),
        (.cooler, "光を白く"), (.warmer, "光を暖かく"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("キー操作")
                .font(.title2.weight(.semibold))
            Text("「変更」を押してから、割り当てたいキーを押します。変更はすぐ反映されます。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Self.labels, id: \.0) { action, label in
                        row(action, label)
                    }
                }
                .padding(.trailing, 6)
            }
            Text(message ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("すべて初期値に戻す") { stopRecording(); keys.resetAll(); message = nil }
                Spacer()
                Button("閉じる") { close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { keys.refresh() }
        .onDisappear(perform: stopRecording)
    }

    private func row(_ action: TimerAction, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(recording == action ? "キーを押してください…" : keys.keys(for: action).map(KeyBindings.display).joined(separator: "  "))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(recording == action ? Color.accentColor : Color.primary)
            Button(recording == action ? "やめる" : "変更") {
                recording == action ? stopRecording() : startRecording(action)
            }
            Button("戻す") { stopRecording(); resetKeys(of: action) }
                .disabled(keys.isDefault(action))
        }
    }

    private func resetKeys(of action: TimerAction) {
        if let owner = keys.reset(action) {
            let ownerLabel = Self.labels.first { $0.0 == owner }?.1 ?? ""
            message = "初期のキーが「\(ownerLabel)」で使われています。先にそちらを変えてください"
        } else {
            message = nil
        }
    }

    private func startRecording(_ action: TimerAction) {
        stopRecording()
        recording = action
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Shortcuts with Command / Control / Option are not bindable; leave them to the system.
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            MainActor.assumeIsolated { record(event, for: action) }
            return nil
        }
    }

    private func record(_ event: NSEvent, for action: TimerAction) {
        guard let key = KeyBindings.recordedName(for: event) else {
            message = "このキーは割り当てられません"
            return
        }
        if let owner = keys.assign(key, to: action) {
            let ownerLabel = Self.labels.first { $0.0 == owner }?.1 ?? ""
            message = "\(KeyBindings.display(key)) は「\(ownerLabel)」で使われています"
        } else {
            message = nil
            stopRecording()
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}
