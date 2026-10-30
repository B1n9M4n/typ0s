import Cocoa
import SwiftUI
import Carbon
import ApplicationServices
import IOKit
import IOKit.hid

// MARK: - Pastel Neumorphic Palette
// Near-white base, two light sources (highlight top-left, shade bottom-right),
// and pastel pairs (soft fill + deeper ink of the same hue) used sparingly.
// Every token resolves per appearance, so the whole UI follows light/dark automatically.
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

extension Color {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static let nmBase = dynamic(rgb(0.925, 0.922, 0.875), rgb(0.106, 0.102, 0.082))      // vintage white / vinyl black
    static let nmRaised = dynamic(rgb(0.965, 0.960, 0.925), rgb(0.165, 0.160, 0.135))    // knobs, active segment
    static let nmLight = dynamic(rgb(1, 1, 0.97, 0.9), rgb(1, 1, 1, 0.05))
    static let nmShade = dynamic(rgb(0.50, 0.47, 0.38, 0.30), rgb(0, 0, 0, 0.55))
    static let nmInk = dynamic(rgb(0.13, 0.12, 0.10), rgb(0.90, 0.90, 0.85))
    static let nmMuted = dynamic(rgb(0.13, 0.12, 0.10, 0.66), rgb(0.90, 0.90, 0.85, 0.66))   // readable over the moving backdrop
}

// Retro palette: vinyl black, tangerine, turquoise, vintage white, cherry tomato (matte, with film grain).
// Each accent is a pair: a soft fill plus a deeper ink of the same hue.
struct Pastel {
    let fill: Color
    let fill2: Color   // gradient partner
    let ink: Color

    var gradient: AnyShapeStyle {
        AnyShapeStyle(LinearGradient(colors: [fill, fill2], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
    /// Colours for the slowly flowing gradient on primary controls
    var flowColors: [Color] { [fill, fill2, fill] }

    // Source colours
    static let vintageWhite = Color(red: 0.902, green: 0.902, blue: 0.847)
    static let tangerineHex = Color(red: 0.914, green: 0.565, blue: 0.231)
    static let turquoiseHex = Color(red: 0.176, green: 0.471, blue: 0.518)
    static let tomatoHex = Color(red: 0.878, green: 0.294, blue: 0.200)

    private static let tomatoFill = Color.dynamic(rgb(0.97, 0.83, 0.78), rgb(0.38, 0.14, 0.10))
    private static let tangerineFill = Color.dynamic(rgb(0.98, 0.88, 0.74), rgb(0.38, 0.24, 0.08))
    private static let tealFill = Color.dynamic(rgb(0.80, 0.89, 0.89), rgb(0.10, 0.26, 0.29))

    /// Cherry tomato: main actions, the built-in keyboard
    static let tomato = Pastel(fill: tomatoFill, fill2: tangerineFill,
                               ink: .dynamic(rgb(0.76, 0.22, 0.12), rgb(0.98, 0.50, 0.40)))
    /// Tangerine: learned words, warnings
    static let tangerine = Pastel(fill: tangerineFill, fill2: tomatoFill,
                                  ink: .dynamic(rgb(0.66, 0.37, 0.06), rgb(0.95, 0.66, 0.33)))
    /// Turquoise: the external keyboard, switches
    static let teal = Pastel(fill: tealFill, fill2: tangerineFill,
                             ink: .dynamic(rgb(0.12, 0.38, 0.43), rgb(0.56, 0.80, 0.84)))

    /// The three accent inks (adapt to light/dark), for text
    static let heatInks: [Color] = [teal.ink, tomato.ink, tangerine.ink]
    /// Fixed colours for the logo, orb and ring, so the white glyph reads in both modes
    static let logoColors: [Color] = [turquoiseHex, tangerineHex, tomatoHex]
}

/// A gradient wider than its view that slides slowly back and forth, so colours flow
struct FlowingGradient: View {
    var colors: [Color]
    var duration: Double = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: colors + colors, startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 3, height: g.size.height)
                .offset(x: phase ? -g.size.width * 2 : 0)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: true)) { phase = true }
        }
    }
}

/// Retro backdrop: soft colour patches drifting slowly behind the window
struct PastelBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate
            // The reference's composition: pale light + turquoise above, a dark band, tangerine + tomato below.
            // Light mode keeps the colours apart and softer, so they don't mix into mud on the paper.
            let dark = scheme == .dark
            ZStack {
                Color.nmBase
                if dark {
                    patch(Pastel.vintageWhite, 0.55, 300, near: (0.25, 0.05), t, 0.0)
                }
                patch(Pastel.turquoiseHex, dark ? 0.85 : 0.40, dark ? 420 : 330, near: (0.80, 0.18), t, 1.3)
                patch(Pastel.tangerineHex, dark ? 0.85 : 0.40, dark ? 400 : 320, near: (0.90, 0.95), t, 2.6)
                patch(Pastel.tomatoHex, dark ? 0.85 : 0.35, dark ? 380 : 300, near: (0.25, 0.95), t, 3.9)
                FilmGrain().opacity(dark ? 0.10 : 0.07)
            }
        }
    }

    /// A soft colour patch that drifts gently around its spot (so the layout stays like the reference)
    private func patch(_ color: Color, _ opacity: Double, _ radius: CGFloat, near p: (CGFloat, CGFloat),
                       _ t: TimeInterval, _ phase: Double) -> some View {
        let at = UnitPoint(x: p.0 + 0.10 * cos(t / 23 + phase), y: p.1 + 0.08 * sin(t / 29 + phase * 1.7))
        return glow(color, opacity: opacity * breathe(t, phase), radius: radius, at: at)
    }

    /// A slow elliptical path around the window centre
    private func orbit(_ t: TimeInterval, period: Double, phase: Double) -> UnitPoint {
        let a = t / period * 2 * .pi + phase
        return UnitPoint(x: 0.5 + 0.45 * cos(a), y: 0.5 + 0.40 * sin(a * 0.8))
    }

    /// Gentle pulse between 80% and 100% brightness
    private func breathe(_ t: TimeInterval, _ phase: Double) -> Double {
        0.9 + 0.1 * sin(t * 0.5 + phase)
    }

    private func glow(_ color: Color, opacity: Double, radius: CGFloat, at center: UnitPoint) -> some View {
        RadialGradient(colors: [color.opacity(opacity), color.opacity(opacity * 0.35), .clear],
                       center: center, startRadius: 0, endRadius: radius)
    }
}

// MARK: - Matte glass (more printed paper than polished crystal)
extension Color {
    static let glassFill = dynamic(rgb(0.96, 0.955, 0.92, 0.62), rgb(0.08, 0.078, 0.062, 0.62))
    static let glassSheen = dynamic(rgb(1, 1, 1, 0.18), rgb(1, 1, 1, 0.04))
    static let glassEdge = dynamic(rgb(1, 1, 0.97, 0.75), rgb(1, 1, 1, 0.12))
    static let glassEdgeLow = dynamic(rgb(1, 1, 1, 0.15), rgb(1, 1, 1, 0.03))
}

/// Fine film grain, drawn once as a tile of random grey pixels and repeated over the window
struct FilmGrain: View {
    private static let tile: NSImage = {
        let size = 160
        var pixels = [UInt8](repeating: 0, count: size * size)
        for i in pixels.indices { pixels[i] = UInt8.random(in: 0...255) }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSImage(cgImage: image, size: NSSize(width: size / 2, height: size / 2))
    }()

    var body: some View {
        Rectangle()
            .fill(ImagePaint(image: Image(nsImage: FilmGrain.tile)))
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }
}

/// Frosted glass pane: translucent fill, a sheen from the top, a bright top edge and a soft shadow
struct GlassSurface<S: InsettableShape>: View {
    var shape: S
    var body: some View {
        shape.fill(Color.glassFill)
            .overlay(shape.fill(LinearGradient(colors: [Color.glassSheen, .clear], startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.glassEdge, Color.glassEdgeLow],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .nmShade, radius: 18, y: 8)
    }
}

extension Font {
    static func nm(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - KeyCode Names
func keyCodeToString(_ code: Int64, flags: CGEventFlags) -> String {
    var parts: [String] = []
    if flags.contains(.maskControl) { parts.append("⌃") }
    if flags.contains(.maskAlternate) { parts.append("⌥") }
    if flags.contains(.maskShift) { parts.append("⇧") }
    if flags.contains(.maskCommand) { parts.append("⌘") }
    let map: [Int64: String] = [
        49: "SPACE", 36: "RETURN", 48: "TAB", 51: "DELETE", 53: "ESC",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        107: "F14", 114: "INS", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        176: "MIC", 60: "R-SHIFT",
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M", 18: "1", 19: "2", 20: "3",
        21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"
    ]
    parts.append(map[code] ?? "KEY \(code)")
    return parts.joined(separator: " ")
}

// MARK: - App State (persisted)
class Typ0sState: ObservableObject {
    static let shared = Typ0sState()
    private let d = UserDefaults.standard

    @Published var isNuPhyConnected = false
    @Published var detectedKeyboardName = "Built-in Keyboard"

    @Published var nuphyKeyCode: Int64 { didSet { d.set(nuphyKeyCode, forKey: "nuphyKey") } }
    @Published var nuphyFlagsRaw: UInt64 { didSet { d.set(nuphyFlagsRaw, forKey: "nuphyFlags") } }
    @Published var macKeyCode: Int64 { didSet { d.set(macKeyCode, forKey: "macKey") } }
    @Published var macFlagsRaw: UInt64 { didSet { d.set(macFlagsRaw, forKey: "macFlags") } }

    @Published var doubleTapRightShiftEnabled: Bool { didSet { d.set(doubleTapRightShiftEnabled, forKey: "dblShift") } }
    @Published var showFloatingPill: Bool { didSet { d.set(showFloatingPill, forKey: "showPill2") } }
    @Published var profileMode: ProfileMode { didSet { d.set(profileMode.rawValue, forKey: "profileMode") } }

    /// Which hotkey profile is live: follow the connected keyboard, or pin one manually
    enum ProfileMode: Int, CaseIterable { case auto, external, builtIn }
    @Published var playSounds: Bool { didSet { d.set(playSounds, forKey: "sounds") } }
    @Published var appearance: AppearanceMode { didSet { d.set(appearance.rawValue, forKey: "appearance") } }
    /// Bold fixes more of your messy words; Careful only fixes when the learned model is very sure
    @Published var fixMode: FixGate.Mode { didSet { d.set(fixMode.rawValue, forKey: "fixMode"); FixGate.mode = fixMode } }
    /// a/an, doubled words, "could of", and stray punctuation like "I think. the"
    @Published var lightGrammar: Bool { didSet { d.set(lightGrammar, forKey: "lightGrammar"); FastTypoEngine.grammarEnabled = lightGrammar } }
    /// Fuller grammar from Harper ("we was" -> "we were"), when harper-cli is installed
    @Published var harperGrammar: Bool { didSet { d.set(harperGrammar, forKey: "harperGrammar"); HarperGrammar.enabled = harperGrammar } }

    enum AppearanceMode: Int, CaseIterable { case auto, light, dark }

    // Hotkey recording: listen -> pending -> Save / Cancel
    @Published var isRecordingFor: RecordingTarget? = nil
    @Published var pendingTarget: RecordingTarget? = nil
    @Published var pendingKeyCode: Int64 = 0
    @Published var pendingFlagsRaw: UInt64 = 0

    @Published var isFlashingSuccess = false
    @Published var lastLatencyMs: Double = 0
    @Published var lastTriggerLabel = ""      // the key that fired the last fix, shown in the pill
    @Published var accessibilityGranted = false

    enum RecordingTarget { case nuphy, mac }

    init() {
        nuphyKeyCode = d.object(forKey: "nuphyKey") as? Int64 ?? 107
        nuphyFlagsRaw = d.object(forKey: "nuphyFlags") as? UInt64 ?? 0
        macKeyCode = d.object(forKey: "macKey") as? Int64 ?? 49
        macFlagsRaw = d.object(forKey: "macFlags") as? UInt64 ?? CGEventFlags.maskAlternate.rawValue
        doubleTapRightShiftEnabled = d.object(forKey: "dblShift") as? Bool ?? true
        // New key so existing installs start with the quieter menu-bar-only status
        showFloatingPill = d.object(forKey: "showPill2") as? Bool ?? false
        if let saved = d.object(forKey: "profileMode") as? Int, let mode = ProfileMode(rawValue: saved) {
            profileMode = mode
        } else {
            // Migrate the old auto-switch toggle: off meant "always use the built-in profile"
            profileMode = (d.object(forKey: "autoSwitch") as? Bool ?? true) ? .auto : .builtIn
        }
        playSounds = d.object(forKey: "sounds") as? Bool ?? true
        appearance = AppearanceMode(rawValue: d.integer(forKey: "appearance")) ?? .auto
        fixMode = FixGate.Mode(rawValue: d.string(forKey: "fixMode") ?? "") ?? .bold
        lightGrammar = d.object(forKey: "lightGrammar") as? Bool ?? true
        harperGrammar = d.object(forKey: "harperGrammar") as? Bool ?? HarperGrammar.isAvailable
        FixGate.mode = fixMode
        FastTypoEngine.grammarEnabled = lightGrammar
        HarperGrammar.enabled = harperGrammar
    }

    var usingExternalProfile: Bool {
        switch profileMode {
        case .auto: return isNuPhyConnected
        case .external: return true
        case .builtIn: return false
        }
    }

    /// The saved hotkey for one keyboard, as shown on its key chip
    func savedHotkeyLabel(_ t: RecordingTarget) -> String {
        t == .nuphy
            ? hotkeyLabel(nuphyKeyCode, flags: CGEventFlags(rawValue: nuphyFlagsRaw), external: true)
            : keyCodeToString(macKeyCode, flags: CGEventFlags(rawValue: macFlagsRaw))
    }

    var activeHotkeyDisplay: String {
        usingExternalProfile
            ? hotkeyLabel(nuphyKeyCode, flags: CGEventFlags(rawValue: nuphyFlagsRaw), external: true)
            : keyCodeToString(macKeyCode, flags: CGEventFlags(rawValue: macFlagsRaw))
    }

    /// NuPhy keyboards send key code 114 (macOS "Help/Insert") from the key printed F14, so call it F14 there
    func hotkeyLabel(_ code: Int64, flags: CGEventFlags, external: Bool) -> String {
        let name = detectedKeyboardName.lowercased()
        if external && code == 114 && flags.isEmpty && (name.contains("nuphy") || name.contains("air75")) { return "F14" }
        return keyCodeToString(code, flags: flags)
    }

    func startRecording(_ t: RecordingTarget) {
        pendingTarget = nil
        isRecordingFor = t
    }

    func capture(keyCode: Int64, flags: CGEventFlags) {
        guard let t = isRecordingFor else { return }
        pendingTarget = t
        pendingKeyCode = keyCode
        pendingFlagsRaw = flags.rawValue
        isRecordingFor = nil
    }

    func savePending() {
        guard let t = pendingTarget else { return }
        if t == .nuphy { nuphyKeyCode = pendingKeyCode; nuphyFlagsRaw = pendingFlagsRaw }
        else { macKeyCode = pendingKeyCode; macFlagsRaw = pendingFlagsRaw }
        pendingTarget = nil
        if playSounds { NSSound(named: "Glass")?.play() }
    }

    func cancelRecording() {
        isRecordingFor = nil
        pendingTarget = nil
    }
}

// MARK: - Hardware Keyboard Detector
class HardwareKeyboardMonitor {
    private var timer: Timer?

    func startMonitoring() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        var external: String? = nil
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in devices {
                guard let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String else { continue }
                let l = name.lowercased()
                if l.contains("nuphy") || l.contains("air75") || l.contains("halo") { external = name; break }
                if !l.contains("internal") && !l.contains("apple") && !l.contains("spi")
                    && !l.contains("headset") && !l.contains("audio") && !l.contains("mouse") {
                    external = name
                }
            }
        }

        DispatchQueue.main.async {
            let s = Typ0sState.shared
            let was = s.isNuPhyConnected
            s.isNuPhyConnected = external != nil
            s.detectedKeyboardName = external ?? "Built-in Keyboard"
            if was != s.isNuPhyConnected && s.playSounds { NSSound(named: "Pop")?.play() }
        }
    }
}

// MARK: - Neumorphic Primitives

/// Soft extruded (raised) or debossed (inset) surface in any shape
struct NeuSurface<S: Shape>: View {
    var shape: S
    var inset: Bool = false
    var depth: CGFloat = 5
    var fill: AnyShapeStyle = AnyShapeStyle(Color.nmBase)
    var flow: [Color]? = nil   // when set, colours slowly flow across the surface

    private var surface: some View {
        shape.fill(fill).overlay {
            if let flow { FlowingGradient(colors: flow).clipShape(shape) }
        }
    }

    var body: some View {
        if inset {
            surface
                .overlay(shape.stroke(Color.nmShade, lineWidth: depth)
                    .blur(radius: depth * 0.8).offset(x: depth * 0.4, y: depth * 0.4).mask(shape))
                .overlay(shape.stroke(Color.nmLight, lineWidth: depth)
                    .blur(radius: depth * 0.8).offset(x: -depth * 0.4, y: -depth * 0.4).mask(shape))
        } else {
            surface
                .shadow(color: .nmShade, radius: depth * 1.4, x: depth, y: depth)
                .shadow(color: .nmLight, radius: depth * 1.4, x: -depth, y: -depth)
        }
    }
}

/// Status dot: colored when on, faint when off
struct StatusDot: View {
    var on: Bool = true
    var color: Color = Pastel.tomato.ink
    var body: some View {
        Circle()
            .fill(on ? color : Color.nmMuted.opacity(0.3))
            .frame(width: 6, height: 6)
            .shadow(color: on ? color.opacity(0.45) : .clear, radius: 3)
    }
}

// MARK: - Logo
/// Text cursor (I-beam) with a small sparkle: a typo being fixed. Drawn in a unit square.
struct LogoGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        // I-beam: stem plus top and bottom caps
        p.move(to: pt(0.40, 0.24)); p.addLine(to: pt(0.40, 0.76))
        p.move(to: pt(0.29, 0.24)); p.addQuadCurve(to: pt(0.40, 0.30), control: pt(0.38, 0.24))
        p.move(to: pt(0.51, 0.24)); p.addQuadCurve(to: pt(0.40, 0.30), control: pt(0.42, 0.24))
        p.move(to: pt(0.29, 0.76)); p.addQuadCurve(to: pt(0.40, 0.70), control: pt(0.38, 0.76))
        p.move(to: pt(0.51, 0.76)); p.addQuadCurve(to: pt(0.40, 0.70), control: pt(0.42, 0.76))
        return p.strokedPath(StrokeStyle(lineWidth: w * 0.075, lineCap: .round, lineJoin: .round))
    }
}

/// Four-point sparkle, filled
struct Sparkle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = r.width / 2, k = R * 0.22
        p.move(to: CGPoint(x: c.x, y: c.y - R))
        p.addQuadCurve(to: CGPoint(x: c.x + R, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + R), control: CGPoint(x: c.x + k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x - R, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - R), control: CGPoint(x: c.x - k, y: c.y - k))
        return p
    }
}

/// Cursor + sparkle in a single colour (used alone for the menu bar template icon)
struct LogoMark: View {
    var color: Color = .white
    var size: CGFloat
    var body: some View {
        ZStack(alignment: .topLeading) {
            LogoGlyph().fill(color)
            Sparkle().fill(color)
                .frame(width: size * 0.30, height: size * 0.30)
                .offset(x: size * 0.56, y: size * 0.16)
        }
        .frame(width: size, height: size)
    }
}

/// App logo: fire squircle with the white cursor + sparkle
struct TyposLogo: View {
    var size: CGFloat = 22
    var animated: Bool = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        shape
            .fill(LinearGradient(colors: Pastel.logoColors,
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay { if animated { FlowingGradient(colors: Pastel.logoColors, duration: 5).clipShape(shape) } }
            .overlay(LogoMark(color: .white, size: size * 0.9))
            .frame(width: size, height: size)
            .shadow(color: Pastel.tomato.ink.opacity(0.3), radius: size * 0.15, y: size * 0.06)
    }
}

enum LogoImages {
    /// Monochrome template icon for the menu bar (macOS tints it for light/dark menu bars)
    @MainActor static func menuBarTemplate() -> NSImage {
        let r = ImageRenderer(content: LogoMark(color: .black, size: 18))
        r.scale = 2
        let img = r.nsImage ?? NSImage()
        img.isTemplate = true
        return img
    }

    /// 1024px app icon PNG on Apple's icon grid (used by build.sh to make AppIcon.icns)
    @MainActor static func writeAppIconPNG(to path: String) -> Bool {
        let r = ImageRenderer(content: TyposLogo(size: 824).padding(100))
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Full-colour logo, e.g. for the menu bar "fixed" flash and the app icon
    @MainActor static func color(size: CGFloat) -> NSImage {
        let r = ImageRenderer(content: TyposLogo(size: size).padding(size * 0.08))
        r.scale = 2
        return r.nsImage ?? NSImage()
    }
}

/// Raised button that sinks into the surface when pressed; pastel pair for primary actions
struct NeuButtonStyle: ButtonStyle {
    var pastel: Pastel? = nil
    var tint: Color = .nmInk
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nm(12, .medium))
            .foregroundColor(pastel?.ink ?? tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(NeuSurface(shape: Capsule(), inset: configuration.isPressed, depth: 3,
                                   fill: pastel?.gradient ?? AnyShapeStyle(Color.nmBase),
                                   flow: pastel?.flowColors))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Small inset track with a raised chip on the selected option
struct NeuSegmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = value } } label: {
                    Text(label)
                        .font(.nm(11, selection == value ? .semibold : .regular))
                        .foregroundColor(selection == value ? .nmInk : .nmMuted)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background {
                            if selection == value {
                                NeuSurface(shape: Capsule(), depth: 2, fill: AnyShapeStyle(Color.nmRaised))
                                    .matchedGeometryEffect(id: "chip", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(NeuSurface(shape: Capsule(), inset: true, depth: 3))
    }
}

/// Quiet section caption
struct Caption: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.nm(11, .medium))
            .foregroundColor(.nmMuted)
    }
}

// MARK: - Floating Top Pill (optional; the menu bar icon is the default status)

/// Small glowing orb whose fire colours slowly swirl; brightens on a successful fix
struct FireOrb: View {
    var angle: Double
    var active: Bool
    var body: some View {
        Circle()
            .fill(AngularGradient(colors: Pastel.logoColors + [Pastel.logoColors[0]],
                                  center: .center, angle: .degrees(angle * 2)))
            .frame(width: 10, height: 10)
            .shadow(color: Pastel.tomato.ink.opacity(active ? 0.8 : 0.35), radius: active ? 6 : 3)
            .scaleEffect(active ? 1.2 : 1)
    }
}

/// Frosted-glass capsule with a slowly rotating fire ring around its edge
struct FloatingPillView: View {
    @ObservedObject var state = Typ0sState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onOpenSettings: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
            let angle = reduceMotion ? 0 : (ctx.date.timeIntervalSinceReferenceDate * 24).truncatingRemainder(dividingBy: 360)
            let ok = state.isFlashingSuccess
            HStack(spacing: 9) {
                FireOrb(angle: angle, active: ok)
                HStack(spacing: 7) {
                    if ok {
                        // The key that fired the fix: screen recorders can't show it, because typ0s swallows it
                        if !state.lastTriggerLabel.isEmpty {
                            Text(state.lastTriggerLabel)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Pastel.tomato.ink)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Pastel.tomato.fill))
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(String(format: "Fixed · %.1f ms", state.lastLatencyMs))
                            .foregroundStyle(LinearGradient(colors: [Pastel.teal.ink, Pastel.tomato.ink],
                                                            startPoint: .leading, endPoint: .trailing))
                    } else {
                        Text("typ0s").foregroundStyle(Color.nmInk.opacity(0.75))
                    }
                }
                .font(.nm(11, .semibold))
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
                Button(action: onOpenSettings) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.nmMuted)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.nmRaised.opacity(0.7)))
                }
                .buttonStyle(.plain)
                .help("Open typ0s")
            }
            .padding(.leading, 13).padding(.trailing, 6).padding(.vertical, 6)
            .background(
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(Color.nmBase.opacity(0.55))
                    Capsule().fill(LinearGradient(colors: [Pastel.teal.fill, Pastel.tomato.fill, Pastel.tangerine.fill],
                                                  startPoint: .leading, endPoint: .trailing))
                        .opacity(ok ? 0.85 : 0.25)
                }
            )
            .overlay(
                Capsule().strokeBorder(
                    AngularGradient(colors: Pastel.logoColors + [Pastel.logoColors[0]],
                                    center: .center, angle: .degrees(angle)),
                    lineWidth: 1.2)
                .opacity(ok ? 0.9 : 0.45)
            )
            .shadow(color: Pastel.tomato.ink.opacity(0.18), radius: 6, y: 2)
            .padding(8) // room for the glow inside the borderless panel
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: ok)
        }
    }
}

// MARK: - Tabs
enum SettingsTab: String, CaseIterable { case keys = "Settings", dictionary = "Dictionary", test = "Test" }

struct DictionaryTab: View {
    @ObservedObject var store = UserDictionaryStore.shared
    @State private var typo = ""
    @State private var word = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("> typ0s learns on its own: a typo you make twice is memorised, and names it doesn't know are protected after \(UserDictionaryStore.learnThreshold) uses. Press ⌘Z right after a fix and nothing from it is learned.")
                .font(.terminal(11)).foregroundColor(Retro.cyan)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                field("Typo (optional)", $typo)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundColor(Retro.orange)
                field("Word", $word)
                Button("Add") {
                    store.addRule(typo: typo, replacement: word)
                    typo = ""; word = ""
                }
                .buttonStyle(RetroButtonStyle(lit: true))
                .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ScrollView {
                VStack(spacing: 0) {
                    if store.customRules.isEmpty {
                        Text("> No words yet. Add one above, or keep writing and typ0s fills this in.")
                            .font(.terminal(11)).foregroundColor(Retro.cream.opacity(0.7))
                            .padding(.vertical, 14).padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(store.customRules) { rule in
                        HStack(spacing: 8) {
                            if rule.typo.isEmpty {
                                Text(rule.replacement).font(.retro(16)).foregroundColor(Retro.cream).retroGlow(Retro.cream, 0.4)
                                tag(rule.learned ? "learned" : "protected", rule.learned ? Retro.orange : Retro.red)
                            } else {
                                Text(rule.typo).font(.terminal(12)).foregroundColor(Retro.cream.opacity(0.6)).strikethrough()
                                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundColor(Retro.orange)
                                Text(rule.replacement).font(.retro(16)).foregroundColor(Retro.cream).retroGlow(Retro.cream, 0.4)
                                if rule.learned { tag("learned", Retro.orange) }
                            }
                            Spacer()
                            Button { store.removeRule(id: rule.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(Retro.cream.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)   // full width even when the list is short
                .padding(.horizontal, 12)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Retro.cream.opacity(0.3), lineWidth: 1.5))
            .frame(maxHeight: .infinity)
        }
    }

    func field(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.terminal(13))
            .foregroundColor(Retro.cream)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Retro.cream.opacity(0.45), lineWidth: 1.5))
    }

    /// Small outlined tag saying where a word came from
    func tag(_ text: String, _ color: Color) -> some View {
        Text(text.uppercased())
            .font(.terminal(10)).foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1))
    }
}

struct TestTab: View {
    @ObservedObject var state = Typ0sState.shared
    // Everyday fast-typing slips; each one is fully corrected by the current engine
    static let samples = [
        "i think the tests were flaky agian, can you rerun the build tomorow morning",
        "the new keybaord feels great but my fingers keep hitting the wrong keys whne i type fast",
        "please recieve the package by friday and seperate the invoices untill the end of the month",
        "my coffee went cold becuase i was writing for an hour straight",
        "the garden looks beautiful after teh rain, everything smells fresh",
        "we definately need a better plan for the launch, maybe a shorter checklist"
    ]
    // Longer everyday paragraphs with natural fast-typing slips (not hand-picked to pass)
    static let longSamples = [
        "so the plan for saturday is pretty simple. we meet at the station around ten, grab coffee at that small place on the corner, adn then walk up to the park before it gets too hot. if it rains we can jsut go to the museum instead, i checked and its free on weekends. please bring a jacket becuase the weather app keeps changing its mind. also, does anyone know if the bakery is still open on sundays? i want to buy bread for my mom on the way back. let me knwo by friday night so i can book the table.",
        "i have been tryign to read more books this year but honestly it is harder than i thought. every evening i sit down wiht a book and after five minutes my phone lights up and taht is the end of it. last week i started leaving the phone in the kitchen and it actually worked, i finished two books in four days. the first one was a slow mystery set in a small fishing town, the second was a memoir abotu a chef who opened a restaurant in tokyo. i think i liked the second one more, mostly beacuse the food descriptions made me so hungry.",
        "quick update on the website. the new homepage is almost done, we jsut need the final photos from the design team and a shorter headline. the contact form is working now but the confirmation email sometimes goes to spam, so i will look into that tomorow. performance is much better than before, the page loads in under two seconds on a normal connection. one thing i am not sure abotu is the colour of the main button, it looks great on my laptop but kind of dull on my phone. coudl someone check it on a different screen and tell me waht you think?",
        "yesterday i finally cleaned my desk adn found so many random things. three pens that dont work, a charger for a phone i sold two years ago, a birthday card i forgot to send, and a tiny plant that somehow survived wihtout any water. i threw most of it away and now the desk feels huge. i also moved the lamp to the left side so the light doesnt hit the screen directly, which makes a big difference at night. the next step is the drawer, but i think taht can wait untill next weekend.",
        "my grandmother called this morning to ask if i was eating enough vegetables, which is her favourite question. we talked for almost an hour abotu her garden, the neighbours, and the new recipe she wants to try for the holidays. she is planning to make a huge pot of soup and freeze half of it so she doesnt have to cook every day. i promised to visit her next month and help her fix the gate taht keeps swinging open in the wind. she said she will make my favourite cake if i come early enough in the afternoon."
    ]
    // Public-domain classics. The text is clean; realistic slips are injected each time one loads.
    static let classicSamples: [(text: String, source: String)] = [
        ("Begin the morning by saying to thyself, I shall meet with the busy-body, the ungrateful, arrogant, deceitful, envious, unsocial. All these things happen to them by reason of their ignorance of what is good and evil.",
         "Marcus Aurelius, Meditations (tr. George Long)"),
        ("I went to the woods because I wished to live deliberately, to front only the essential facts of life, and see if I could not learn what it had to teach, and not, when I came to die, discover that I had not lived.",
         "Henry David Thoreau, Walden"),
        ("Trust thyself: every heart vibrates to that iron string. Accept the place the divine providence has found for you, the society of your contemporaries, the connection of events.",
         "Ralph Waldo Emerson, Self-Reliance"),
        ("Hold every hour in your grasp. Lay hold of to-day's task, and you will not need to depend so much upon to-morrow's. While we are postponing, life speeds by.",
         "Seneca, Moral Letters (tr. Richard Gummere)"),
        ("Men are disturbed not by things, but by the views which they take of things.",
         "Epictetus, Enchiridion (tr. Thomas Higginson)")
    ]

    enum SampleSet: Hashable { case short, long, classic }

    /// Words shown with a fading highlight right after a fix
    struct Reveal {
        let words: [(text: String, changed: Bool)]
        let start: Date
    }

    @State private var set: SampleSet = .short
    @State private var index = 0
    @State private var text = TestTab.samples[0]
    @State private var ms: Double = 0
    @State private var reveal: Reveal? = nil
    @State private var classicClean: String? = nil      // clean original, for scoring
    @State private var injected: Set<Int> = []          // word positions that got a slip
    @State private var score: String? = nil

    private var setCount: Int {
        switch set {
        case .short: return TestTab.samples.count
        case .long: return TestTab.longSamples.count
        case .classic: return TestTab.classicSamples.count
        }
    }

    private var caption: String {
        if set == .classic { return TestTab.classicSamples[index].source }
        return "Example \(index + 1) of \(setCount)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(caption.uppercased()).font(.terminal(11)).foregroundColor(Retro.cyan).lineLimit(1)
                Spacer()
                RetroSegmented(options: [(.short, "Short"), (.long, "Long"), (.classic, "Classic")], selection: $set)
            }
            .onChange(of: set) { load(0) }
            // Hotkey fixes (⌥T, F14, Right Shift ×2) also show their time here, not just the Fix button
            .onChange(of: state.lastLatencyMs) { ms = state.lastLatencyMs }

            ZStack(alignment: .topLeading) {
                if let r = reveal {
                    RevealText(reveal: r)
                        .padding(.horizontal, 5) // match TextEditor's inner inset so words don't jump
                        .contentShape(Rectangle())
                        .onTapGesture { reveal = nil }
                } else {
                    TextEditor(text: $text)
                        .font(.terminal(14))
                        .foregroundColor(Retro.cream)
                        .scrollContentBackground(.hidden)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Retro.cream.opacity(0.3), lineWidth: 1.5))

            HStack(spacing: 12) {
                Button("Fix", action: fix)
                    .buttonStyle(RetroButtonStyle(lit: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Fix (⌘↩)")
                Button(set == .classic ? "New slips" : "Next example") {
                    load(set == .classic ? index : (index + 1) % setCount)
                }
                .buttonStyle(RetroButtonStyle())
                if set == .classic {
                    Button("Next text") { load((index + 1) % setCount) }
                        .buttonStyle(RetroButtonStyle())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ms > 0 ? String(format: "%.2f ms", ms) : "— ms")
                        .font(.terminal(12))
                        .foregroundColor(ms > 0 ? Retro.cyan : Retro.cream.opacity(0.6))
                    if let score {
                        Text(score).font(.terminal(11)).foregroundColor(Retro.orange)
                    }
                }
            }
        }
    }

    private func load(_ i: Int) {
        index = i
        ms = 0; score = nil; reveal = nil
        switch set {
        case .short: text = TestTab.samples[i]; classicClean = nil
        case .long: text = TestTab.longSamples[i]; classicClean = nil
        case .classic:
            let clean = TestTab.classicSamples[i].text
            let slipped = TypoInjector.inject(into: clean)
            text = slipped.text
            injected = slipped.positions
            classicClean = clean
        }
    }

    private func fix() {
        let before = text
        DispatchQueue.global(qos: .userInitiated).async {   // Harper's grammar check takes ~0.3 s
            let t0 = CFAbsoluteTimeGetCurrent()
            let after = FastTypoEngine().fixAll(before)
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            DispatchQueue.main.async { show(before: before, after: after, ms: elapsed) }
        }
    }

    private func show(before: String, after: String, ms elapsed: Double) {
        ms = elapsed
        text = after
        if let clean = classicClean { score = TypoInjector.score(clean: clean, fixed: after, slips: injected) }

        let words = WordDiff.mark(old: before, new: after)
        guard words.contains(where: { $0.changed }) else { return }
        let r = Reveal(words: words, start: Date())
        reveal = r
        DispatchQueue.main.asyncAfter(deadline: .now() + RevealText.duration) {
            if reveal?.start == r.start { withAnimation(.easeOut(duration: 0.2)) { reveal = nil } }
        }
    }
}

/// Fixed text where each replaced word lights up in the rainbow stripe colours, one after another, then settles
struct RevealText: View {
    static let duration: Double = 2.0
    let reveal: TestTab.Reveal

    var body: some View {
        TimelineView(.animation) { ctx in
            Text(attributed(elapsed: ctx.date.timeIntervalSince(reveal.start)))
                .font(.terminal(14))   // same face as the editor, so words don't jump
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func attributed(elapsed: Double) -> AttributedString {
        var out = AttributedString()
        var order = 0
        let tints = Retro.stripes
        for (i, w) in reveal.words.enumerated() {
            var word = AttributedString(w.text)
            word.foregroundColor = Retro.cream
            if w.changed {
                // Stagger each word, then fade its highlight out
                let local = max(0, elapsed - Double(order) * 0.06)
                let tint = tints[order % tints.count]
                let strength = local < 0.15 ? local / 0.15 : max(0, 1 - (local - 0.6) / 1.0)
                if strength > 0 {
                    word.backgroundColor = tint.opacity(min(1, strength) * 0.85)
                    if strength > 0.4 { word.foregroundColor = Retro.screen }
                }
                order += 1
            }
            out += word
            if i < reveal.words.count - 1 { out += AttributedString(" ") }
        }
        return out
    }
}

/// Marks which words in the new text are new or changed (longest-common-subsequence on words)
enum WordDiff {
    static func mark(old: String, new: String) -> [(text: String, changed: Bool)] {
        let a = old.components(separatedBy: " ")
        let b = new.components(separatedBy: " ")
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var kept = Set<Int>()
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { kept.insert(j); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return b.enumerated().map { ($0.element, !kept.contains($0.offset)) }
    }
}

/// Adds realistic fast-typing slips to clean text, and scores how well a fix recovered it
enum TypoInjector {
    private static let engine = FastTypoEngine()
    private static let letters = Array("abcdefghijklmnopqrstuvwxyz")

    private static func neighbours(of c: Character) -> [Character] {
        letters.filter { $0 != c && engine.qwertyKeyDistance(c, $0) < 0.5 }
    }

    /// Splits a token into leading punctuation, letters, trailing punctuation
    private static func split(_ token: String) -> (String, String, String) {
        var core = Substring(token), pre = "", suf = ""
        while let f = core.first, !f.isLetter { pre.append(f); core = core.dropFirst() }
        while let l = core.last, !l.isLetter { suf.insert(l, at: suf.startIndex); core = core.dropLast() }
        return (pre, String(core), suf)
    }

    static func inject(into clean: String) -> (text: String, positions: Set<Int>) {
        var words = clean.components(separatedBy: " ")
        let eligible = words.indices.filter {
            let core = split(words[$0]).1
            return core.count >= 4 && core.allSatisfy { $0.isLetter }
        }
        let count = min(eligible.count, max(3, eligible.count / 5))
        let picked = Set(eligible.shuffled().prefix(count))
        for i in picked {
            let (pre, core, suf) = split(words[i])
            words[i] = pre + slip(core) + suf
        }
        return (words.joined(separator: " "), picked)
    }

    /// One physical slip: neighbour key, swapped pair, switch chatter, dropped key, or key bleed
    private static func slip(_ word: String) -> String {
        var c = Array(word)
        for _ in 0..<6 {
            var t = c
            let p = Int.random(in: 1..<t.count - 1)
            let lower = Character(t[p].lowercased())
            switch Int.random(in: 0..<5) {
            case 0: if let n = neighbours(of: lower).randomElement() { t[p] = n }
            case 1: if t[p] != t[p + 1] { t.swapAt(p, p + 1) }
            case 2: t.insert(t[p], at: p)
            case 3: t.remove(at: p)
            default: if let n = neighbours(of: lower).randomElement() { t.insert(n, at: p + 1) }
            }
            if t != c { c = t; break }
        }
        return String(c)
    }

    static func score(clean: String, fixed: String, slips: Set<Int>) -> String {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        let a = clean.components(separatedBy: " ").map(norm)
        let b = fixed.components(separatedBy: " ").map(norm)
        guard a.count == b.count else { return "Word count changed (a split or join)" }
        let recovered = slips.filter { a[$0] == b[$0] }.count
        let wrong = a.indices.filter { !slips.contains($0) && a[$0] != b[$0] }.count
        return "Recovered \(recovered) of \(slips.count) slips" + (wrong > 0 ? " · \(wrong) wrong change\(wrong == 1 ? "" : "s")" : "")
    }
}

// MARK: - Main Window
struct SettingsDashboardView: View {
    @ObservedObject var state = Typ0sState.shared
    @State private var tab: SettingsTab = .keys

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (sits under the transparent title bar / traffic lights)
            HStack(alignment: .center, spacing: 10) {
                RetroLogo()
                Spacer()
                HStack(spacing: 6) {
                    StatusDot(on: true, color: state.usingExternalProfile ? Retro.cyan : Retro.red)
                    Text(state.detectedKeyboardName.uppercased())
                        .font(.terminal(11))
                        .foregroundColor(Retro.cream.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .padding(.top, 40)
            .padding(.horizontal, 28)

            RetroTabs(tab: $tab)
                .padding(.horizontal, 28).padding(.top, 22)

            if !state.accessibilityGranted {
                HStack(spacing: 10) {
                    StatusDot(on: true, color: Retro.orange)
                    Text("> Hotkeys need Accessibility permission")
                        .font(.terminal(12))
                        .foregroundColor(Retro.orange)
                        .retroGlow(Retro.orange, 0.5)
                    Spacer()
                    Button("Grant access") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }.buttonStyle(RetroButtonStyle(lit: true))
                }
                .padding(.horizontal, 28).padding(.top, 18)
            }

            Group {
                switch tab {
                // Scrolls so the last rows are never cut off; padding sits inside so card shadows aren't clipped
                case .keys:
                    ScrollView { RetroSettingsTab().padding(28) }
                        .scrollIndicators(.never)
                case .dictionary: DictionaryTab().padding(28)
                case .test: TestTab().padding(28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 600, height: 600)
        .background(RetroBackdrop())
        .overlay(CRTOverlay())
        .preferredColorScheme(.dark)   // a black screen in every appearance
        .ignoresSafeArea()   // paint under the transparent title bar too, or a dark strip shows at the top
    }
}
