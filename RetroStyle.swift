import SwiftUI

// MARK: - Retro settings
// 80s retro-futurism: glowing cream type on a black CRT, rainbow stripe bands, outlined badges,
// and the main settings read as one sentence.

extension Font {
    /// Heavy condensed display face, like an 80s logo badge
    static func retro(_ size: CGFloat) -> Font {
        .custom("Futura-CondensedExtraBold", size: size)
    }
    /// Terminal text for the small print
    static func terminal(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

/// Black screen, phosphor cream, and the four rainbow stripes
enum Retro {
    static let screen = Color(red: 0.02, green: 0.02, blue: 0.02)
    static let cream = Color(red: 0.95, green: 0.93, blue: 0.86)
    static let red = Color(red: 0.95, green: 0.22, blue: 0.17)
    static let orange = Color(red: 0.98, green: 0.52, blue: 0.13)
    static let yellow = Color(red: 0.99, green: 0.81, blue: 0.20)
    static let cyan = Color(red: 0.13, green: 0.80, blue: 0.92)
    static let stripes: [Color] = [red, orange, yellow, cyan]
}

extension Notification.Name {
    /// Posted when the settings window opens, so the screen can power on
    static let typ0sSettingsOpened = Notification.Name("typ0sSettingsOpened")
}

extension View {
    /// Phosphor bloom, as if the colour were lit on a CRT
    func retroGlow(_ color: Color = Retro.cream, _ strength: Double = 1) -> some View {
        shadow(color: color.opacity(0.35 * strength), radius: 2)
            .shadow(color: color.opacity(0.12 * strength), radius: 8)
    }
}

/// Black screen with a faint lift in the middle, like a lit tube
struct RetroBackdrop: View {
    var body: some View {
        ZStack {
            Retro.screen
            RadialGradient(colors: [Retro.cream.opacity(0.04), .clear], center: .center, startRadius: 0, endRadius: 420)
        }
    }
}

/// The tube itself: fine still scanlines and soft dark corners. No flicker or rolling band, so nothing distracts.
struct CRTOverlay: View {
    var body: some View {
        Canvas { g, size in
            var y: CGFloat = 0
            while y < size.height {
                g.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.14)))
                y += 3
            }
        }
        .overlay(RadialGradient(colors: [.clear, .black.opacity(0.3)], center: .center, startRadius: 260, endRadius: 520))
        .allowsHitTesting(false)
    }
}

/// Confident arrival: fast start, long soft landing
extension Animation {
    static func arrive(_ duration: Double) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: duration) }
}

/// Stacked colour bars that taper toward the leading edge, the 80s logo stripe.
/// When `drawn` turns on, the bars shoot out from the badge one after another.
struct StripeFan: View {
    var colors: [Color] = Retro.stripes
    var width: CGFloat = 34
    var bar: CGFloat = 4
    var drawn = true
    var body: some View {
        VStack(alignment: .trailing, spacing: bar * 0.6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { i, c in
                Rectangle().fill(c)
                    .frame(width: width * (0.55 + 0.15 * CGFloat(i)), height: bar)
                    .retroGlow(c, 0.6)
                    .scaleEffect(x: drawn ? 1 : 0, anchor: .trailing)
                    .animation(.arrive(0.35).delay(drawn ? Double(i) * 0.06 : 0), value: drawn)
            }
        }
    }
}

/// The title: stripe fan running into an outlined badge
struct RetroLogo: View {
    var drawn = true
    var body: some View {
        HStack(spacing: 0) {
            StripeFan(width: 30, bar: 4, drawn: drawn)
            Text("typ0s")
                .font(.retro(26))
                .foregroundColor(Retro.cream)
                .retroGlow()
                .padding(.horizontal, 10).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Retro.cream, lineWidth: 2).retroGlow())
        }
    }
}

/// Tabs as outlined badges, the chosen one lit, over a still rainbow rule
struct RetroTabs: View {
    @Binding var tab: SettingsTab
    var body: some View {
        VStack(spacing: 10) {
            RetroSegmented(options: SettingsTab.allCases.map { ($0, $0.rawValue) }, selection: $tab, size: 15)
                .frame(maxWidth: .infinity, alignment: .leading)
            LinearGradient(colors: Retro.stripes, startPoint: .leading, endPoint: .trailing)
                .frame(height: 2)
        }
    }
}

/// Outlined boxes side by side; the chosen one lights up cream, and the light slides to a new choice
struct RetroSegmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var size: CGFloat = 13
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.0) { value, label in
                let chosen = selection == value
                Button { withAnimation(.arrive(0.24)) { selection = value } } label: {
                    Text(label)
                        .font(.retro(size))
                        .foregroundColor(chosen ? Retro.screen : Retro.cream.opacity(0.75))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: 4).fill(Retro.cream)
                                    .matchedGeometryEffect(id: "lit", in: ns)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Retro.cream.opacity(chosen ? 1 : 0.35), lineWidth: 1.5))
                        .retroGlow(Retro.cream, chosen ? 0.8 : 0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Square switch: an outlined slot with a block that lights turquoise when on
struct RetroToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 3).stroke(Retro.cream.opacity(configuration.isOn ? 0.9 : 0.35), lineWidth: 1.5)
                    .frame(width: 44, height: 20)
                RoundedRectangle(cornerRadius: 2)
                    .fill(configuration.isOn ? Retro.cyan : Retro.cream.opacity(0.3))
                    .frame(width: 18, height: 12)
                    .retroGlow(Retro.cyan, configuration.isOn ? 1 : 0)
                    .padding(.horizontal, 4)
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
        }
    }
}

/// Outlined cream button; lit for the main action
struct RetroButtonStyle: ButtonStyle {
    var lit = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.retro(14))
            .foregroundColor(lit ? Retro.screen : Retro.cream)
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 4).fill(lit ? Retro.cream : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Retro.cream, lineWidth: 1.5))
            .retroGlow(Retro.cream, 0.7)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A hotkey as an outlined key badge: click it, then press the new hotkey. Lit in the keyboard's colour when in use.
struct RetroKey: View {
    @ObservedObject var state = Typ0sState.shared
    let target: Typ0sState.RecordingTarget
    var inUse: Bool

    private var hue: Color { target == .mac ? Retro.red : Retro.cyan }
    private var label: String {
        if state.isRecordingFor == target { return "Press a key…" }
        if state.pendingTarget == target {
            return state.hotkeyLabel(state.pendingKeyCode, flags: CGEventFlags(rawValue: state.pendingFlagsRaw),
                                     external: target == .nuphy)
        }
        return state.savedHotkeyLabel(target)
    }

    private var listening: Bool { state.isRecordingFor == target }

    var body: some View {
        Button { state.startRecording(target) } label: {
            // While it waits for the new hotkey, the key's yellow edge pulses gently, about once a second
            TimelineView(.periodic(from: .now, by: 0.6)) { ctx in
                let blinkOn = Int(ctx.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
                let edge = listening ? Retro.yellow.opacity(blinkOn ? 1 : 0.5) : (inUse ? hue : Retro.cream.opacity(0.5))
                HStack(spacing: 8) {
                    StripeFan(colors: inUse ? [hue, Retro.orange, Retro.yellow] : Array(repeating: Retro.cream.opacity(0.25), count: 3),
                              width: 16, bar: 3)
                    Text(label)
                        .font(.retro(20))
                        .foregroundColor(listening ? Retro.yellow : Retro.cream.opacity(inUse ? 1 : 0.72))
                        .retroGlow(listening ? Retro.yellow : Retro.cream, inUse || listening ? 1 : 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(edge, lineWidth: 2))
                .animation(.easeInOut(duration: 0.4), value: blinkOn)
                .retroGlow(listening ? Retro.yellow : hue, listening || inUse ? 0.6 : 0)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help("Click, then press the new hotkey")
    }
}

/// Save or cancel a hotkey while it's being recorded
struct RecordingBar: View {
    @ObservedObject var state = Typ0sState.shared
    var body: some View {
        if state.pendingTarget != nil || state.isRecordingFor != nil {
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { state.cancelRecording() }.buttonStyle(RetroButtonStyle())
                if state.pendingTarget != nil {
                    Button("Save hotkey") { state.savePending() }
                        .buttonStyle(RetroButtonStyle(lit: true)).keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// The settings tab: hotkeys and strength as one sentence, the rest as rows with dotted rules between
struct RetroSettingsTab: View {
    @ObservedObject var state = Typ0sState.shared
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                words("Fix my writing when I press")
                HStack(spacing: 10) {
                    RetroKey(target: .mac, inUse: !state.usingExternalProfile)
                    words("on the MacBook keyboard,")
                }
                HStack(spacing: 10) {
                    RetroKey(target: .nuphy, inUse: state.usingExternalProfile)
                    words(state.isNuPhyConnected ? "on \(state.detectedKeyboardName)." : "on an external keyboard.")
                }
                HStack(spacing: 8) {
                    words("and fix")
                    choice("boldly", .bold)
                    words("or")
                    choice("carefully", .careful)
                }
                .padding(.top, 4)
                Text(state.fixMode == .bold ? "> Bold fixes more of your messy words" : "> Careful only fixes when it's very sure")
                    .font(.terminal(11)).foregroundColor(Retro.cyan)
            }
            RecordingBar()
            rows
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            rule
            row {
                label("Use hotkey from")
                Spacer()
                RetroSegmented(options: [(.auto, "Auto"), (.external, "External"), (.builtIn, "Built-in")],
                               selection: $state.profileMode)
            }
            toggle("Double-tap Right Shift", "Works as the hotkey on any keyboard", $state.doubleTapRightShiftEnabled)
            toggle("Light grammar", "a/an, “the the”, stray periods", $state.lightGrammar)
            toggle("Grammar check by Harper",
                   HarperGrammar.isAvailable ? "“we was” → “we were”" : "Install Harper first: brew install harper",
                   $state.harperGrammar)
                .disabled(!HarperGrammar.isAvailable)
            toggle("Floating pill", "Off: only the menu bar icon", $state.showFloatingPill)
            toggle("Sounds", nil, $state.playSounds)
        }
        .toggleStyle(RetroToggleStyle())
    }

    private func words(_ s: String) -> some View {
        Text(s).font(.retro(22)).foregroundColor(Retro.cream).retroGlow(Retro.cream, 0.7)
    }

    /// A word you click to choose; the chosen one is lit, and its orange underline slides across to a new choice
    private func choice(_ word: String, _ mode: FixGate.Mode) -> some View {
        let chosen = state.fixMode == mode
        return Button { withAnimation(.arrive(0.28)) { state.fixMode = mode } } label: {
            Text(word)
                .font(.retro(22))
                .foregroundColor(chosen ? Retro.orange : Retro.cream.opacity(0.62))
                .retroGlow(Retro.orange, chosen ? 1 : 0)
                .overlay(alignment: .bottom) {
                    if chosen {
                        Rectangle().fill(Retro.orange).frame(height: 2)
                            .retroGlow(Retro.orange, 0.8)
                            .matchedGeometryEffect(id: "underline", in: ns)
                            .offset(y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var rule: some View {
        Line().stroke(Retro.cream.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 3])).frame(height: 1)
    }

    private func label(_ title: String, _ hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.retro(15)).foregroundColor(Retro.cream).retroGlow(Retro.cream, 0.5)
            if let hint { Text(hint).font(.terminal(11)).foregroundColor(Retro.cyan) }
        }
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack { content() }.padding(.vertical, 11)
            rule
        }
    }

    private func toggle(_ title: String, _ hint: String?, _ isOn: Binding<Bool>) -> some View {
        row { Toggle(isOn: isOn) { label(title, hint) } }
    }
}

/// A straight horizontal line, for dashed rules
struct Line: Shape {
    func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
}
