import SwiftUI

struct TimerFaceView: View {
    @ObservedObject var model: TimerModel
    @Environment(\.colorScheme) private var colorScheme


    private var hairline: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.04)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Key hints appear while focused after pressing "?".
    private var showHints: Bool { model.isFocused && model.showHelp }

    /// White blended towards warm amber by `model.warmth`.
    private func tint(_ white: Double, _ warm: (r: Double, g: Double, b: Double)) -> Color {
        let w = model.warmth
        return Color(red: white + (warm.r - white) * w,
                     green: white + (warm.g - white) * w,
                     blue: white + (warm.b - white) * w)
    }
    private var glowColor: Color { tint(0.96, (1.0, 0.74, 0.40)) }
    private var digitColor: Color { tint(0.98, (1.0, 0.86, 0.64)) }

    var body: some View {
        face
            .foregroundStyle(.primary)
            .background(Color.clear)
            .animation(.easeOut(duration: 0.18), value: model.isFocused)
            .animation(.easeOut(duration: 0.18), value: model.isRunning)
            .animation(.spring(response: 0.42, dampingFraction: 0.8), value: model.showHelp)
    }

    /// Frosted glass normally; solid surface while the panel has keyboard focus.
    private func surface<S: InsettableShape>(_ shape: S) -> some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
                .opacity(model.isFocused ? 1 : 0.45)
            shape.fill(Color(nsColor: .windowBackgroundColor))
                .opacity(model.isFocused ? 1 : 0)
            shape.strokeBorder(hairline, lineWidth: 1)
        }
    }

    /// Soft luminous disc: black core, glowing white arc for the remaining time, dark edge.
    private var aura: some View {
        let core = Color(white: 0.03)
        let glow = glowColor
        return ZStack {
            // The frame must be larger than the stroke plus its blur; otherwise the blurred outer edge
            // is cut flat at the top, bottom, left and right.
            Circle()
                .inset(by: 19) // ring path radius 92 inside a 222 frame, leaving room for the blur
                .trim(from: 0, to: model.progress)
                .stroke(glow, style: StrokeStyle(lineWidth: 22, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(model.isRunning ? nil : .easeInOut(duration: 0.9), value: model.progress)
                .frame(width: 222, height: 222)
                .blur(radius: 3)
            // Dark core only: the elapsed part of the ring is fully transparent.
            Circle().fill(RadialGradient(stops: [.init(color: core.opacity(0.97), location: 0),
                                                 .init(color: core.opacity(0.97), location: 0.84),
                                                 .init(color: core.opacity(0), location: 1)],
                                         center: .center, startRadius: 0, endRadius: 80))
        }
        .frame(width: 222, height: 222)
        .opacity(model.isFocused ? 1 : 0.72)
    }

    @ViewBuilder
    private var face: some View {
        if model.mode == .timer {
            ZStack {
                aura
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(model.isEditing || model.isAlarming))) { timeline in
                    // While typing a time, the digits pulse instead of showing a caret.
                    let phase = timeline.date.timeIntervalSinceReferenceDate
                    let pulse = (model.isEditing || model.isAlarming) ? 0.62 + 0.38 * cos(phase * 2 * .pi / 1.1) : 1.0
                    Text(model.faceText)
                        .font(.system(size: 40, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(digitColor.opacity(model.isFocused ? 1 : 0.78))
                        .shadow(color: glowColor.opacity(model.isFocused ? 0.32 : 0.08), radius: 3)
                        .shadow(color: glowColor.opacity(model.isFocused ? 0.16 : 0.04), radius: 9)
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                        .padding(.horizontal, 36)
                        .opacity(pulse)
                }
                .offset(y: showHints ? -34 : 0)
                hints
                    .environment(\.colorScheme, .dark) // sits on the dark disc in any theme
                    .offset(y: 36)
                    .opacity(showHints ? 1 : 0)
                    .scaleEffect(showHints ? 1 : 0.9)
                    .blur(radius: showHints ? 0 : 5)
            }
            .frame(width: 222, height: 222)
            .contentShape(Circle())
            .onTapGesture { model.stopAlarm() }
        } else {
            ZStack {
                surface(RoundedRectangle(cornerRadius: 26, style: .continuous))
                Text(model.stopwatchText)
                    .font(.system(size: 42, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .offset(y: showHints ? -18 : 0)
                hints
                    .offset(y: 28)
                    .opacity(showHints ? 1 : 0)
                    .scaleEffect(showHints ? 1 : 0.9)
                    .blur(radius: showHints ? 0 : 5)
            }
            .frame(width: 245, height: 105)
        }
    }

    private var hints: some View {
        VStack(spacing: 3) {
            if model.mode == .timer {
                hintRow([(key(.startStop), "開始/停止"), (key(.reset), "リセット")])
                let presets: [TimerAction] = [.preset1, .preset2, .preset3]
                hintRow(model.presetMinutes.enumerated().map { (key(presets[$0.offset]), "\($0.element)分") })
                hintRow([(key(.enterTime), "入力"), (key(.switchMode), "切替")])
            } else {
                hintRow([(key(.startStop), "開始/停止"), (key(.reset), "リセット"), (key(.switchMode), "切替")])
            }
        }
        .font(.system(size: 9, design: .rounded))
        .foregroundStyle(.secondary)
    }

    /// The first key bound to the action, as shown on the face.
    private func key(_ action: TimerAction) -> String {
        KeyBindings.shared.keys(for: action).first.map(KeyBindings.display) ?? "–"
    }

    private func hintRow(_ items: [(String, String)]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 3) {
                    Text(item.0)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.75))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                    Text(item.1)
                }
            }
        }
        .lineLimit(1)
    }
}
