import Cocoa
import SwiftUI
import Carbon
import ApplicationServices
import Combine

/// Lets the first click on a background window go straight to the button under it,
/// instead of only bringing the window forward (typ0s is a menu bar app, so its window is often in the back)
class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class FloatingPillPanel: NSPanel {
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var pillPanel: FloatingPillPanel!
    var settingsWindow: NSWindow?
    
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var isProcessing = false
    
    let engine = FastTypoEngine()
    let keyboardMonitor = HardwareKeyboardMonitor()
    let state = Typ0sState.shared
    var cancellables = Set<AnyCancellable>()
    
    // Double-tap Right Shift detector
    var lastRightShiftTime: TimeInterval = 0
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupFloatingPillWindow()
        setupMenuBar()
        setupMainMenu()
        checkAccessibilityPermissions()
        setupEventTap()
        keyboardMonitor.startMonitoring()
        openSettingsWindow() // Show settings dashboard on launch so user sees it right away!
        
        state.$showFloatingPill
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                if visible {
                    self?.pillPanel?.orderFrontRegardless()
                } else {
                    self?.pillPanel?.orderOut(nil)
                }
            }
            .store(in: &cancellables)

        // Auto follows the system; Light/Dark pin the whole app (window + pill)
        state.$appearance
            .receive(on: RunLoop.main)
            .sink { mode in
                switch mode {
                case .auto: NSApp.appearance = nil
                case .light: NSApp.appearance = NSAppearance(named: .aqua)
                case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
                }
            }
            .store(in: &cancellables)

        // Menu bar icon doubles as the quiet status indicator
        state.$isFlashingSuccess
            .receive(on: RunLoop.main)
            .sink { [weak self] flashing in self?.updateStatusButton(flashing: flashing) }
            .store(in: &cancellables)
    }

    func updateStatusButton(flashing: Bool) {
        guard let button = statusItem?.button else { return }
        if flashing {
            // Full-colour logo + latency while a fix is shown
            button.image = flashIcon
            button.title = String(format: " %.1f ms", state.lastLatencyMs)
        } else {
            button.image = templateIcon
            button.title = ""
        }
        button.setAccessibilityLabel(flashing ? "typ0s: fixed" : "typ0s")
    }

    /// Where the settings window collapses to / expands from: the pill if shown, else the menu bar icon
    func collapseAnchorFrame() -> NSRect {
        if state.showFloatingPill, pillPanel.isVisible { return pillPanel.frame }
        if let iconFrame = statusItem.button?.window?.frame { return iconFrame }
        return pillPanel.frame
    }
    
    // MARK: - Top Floating Pill Window
    func setupFloatingPillWindow() {
        let pillWidth: CGFloat = 266
        let pillHeight: CGFloat = 48 // includes padding for the neumorphic shadows
        
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Top-center, just below the menu bar (clear of the notch)
        let xPos = screenFrame.origin.x + (screenFrame.width - pillWidth) / 2.0
        let yPos = screenFrame.origin.y + screenFrame.height - pillHeight
        
        let rect = NSRect(x: xPos, y: yPos, width: pillWidth, height: pillHeight)
        pillPanel = FloatingPillPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        pillPanel.level = .statusBar
        pillPanel.backgroundColor = .clear
        pillPanel.isOpaque = false
        pillPanel.hasShadow = false // the SwiftUI view draws its own soft shadows
        pillPanel.isMovableByWindowBackground = true // Drag the pill anywhere
        pillPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let hostingView = FirstClickHostingView(rootView: FloatingPillView(
            onOpenSettings: { [weak self] in self?.openSettingsWindow() }
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
        pillPanel.contentView = hostingView
        if state.showFloatingPill { pillPanel.orderFrontRegardless() }
    }
    
    var savedSettingsFrame: NSRect?
    
    func openSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "typ0s"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false   // drag by the top edge; background drags could swallow button clicks
            window.isReleasedWhenClosed = false
            let host = FirstClickHostingView(rootView: SettingsDashboardView())
            if #available(macOS 13.0, *) { host.sizingOptions = [] }
            window.contentView = host
            window.center()
            
            // Green button: disabled. Yellow button: collapse up into the top pill (never to the Dock).
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            if let yellow = window.standardWindowButton(.miniaturizeButton) {
                yellow.target = self
                yellow.action = #selector(collapseToPill)
            }
            settingsWindow = window
        }
        guard let window = settingsWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        
        if !window.isVisible, let target = savedSettingsFrame {
            // Expand out of the pill
            window.setFrame(collapseAnchorFrame(), display: false)
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(target, display: true)
                window.animator().alphaValue = 1
            }
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    @objc func collapseToPill() {
        guard let window = settingsWindow else { return }
        state.cancelRecording()
        savedSettingsFrame = window.frame
        let anchor = collapseAnchorFrame()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(anchor, display: true)
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
            window.alphaValue = 1
            if let f = self.savedSettingsFrame { window.setFrame(f, display: false) }
        })
    }
    
    lazy var templateIcon: NSImage = MainActor.assumeIsolated { LogoImages.menuBarTemplate() }
    lazy var flashIcon: NSImage = {
        let img = MainActor.assumeIsolated { LogoImages.color(size: 16) }
        img.size = NSSize(width: 18, height: 18)
        return img
    }()

    func setupMenuBar() {
        NSApp.applicationIconImage = MainActor.assumeIsolated { LogoImages.color(size: 256) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        updateStatusButton(flashing: false)
        
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open typ0s Settings...", action: #selector(openSettingsAction), keyEquivalent: ",")
        openItem.target = self
        menu.addItem(openItem)
        
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit typ0s", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    /// Menu bar apps get no menus by default, so ⌘Q, ⌘, ⌘W and copy/paste do nothing in our window.
    /// This invisible main menu gives the settings window the standard shortcuts.
    func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "typ0s")
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide typ0s", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit typ0s", action: #selector(quitApp), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize to Pill", action: #selector(collapseToPill), keyEquivalent: "m").target = self
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    /// Opening typ0s again (Spotlight, Launchpad, Finder) while it's running shows settings,
    /// so you can always reach it even when the menu bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }

    @objc func openSettingsAction() {
        openSettingsWindow()
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        state.accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }
    
    func setupEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            return appDelegate.handleEvent(proxy: proxy, type: type, event: event)
        }
        
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: refcon
        ) else {
            state.accessibilityGranted = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.setupEventTap()
            }
            return
        }
        
        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), self.runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DispatchQueue.main.async {
            self.state.accessibilityGranted = true
        }
    }
    
    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        
        // ⌘Z soon after a fix means the fix was unwanted: don't learn from it (the key still goes through)
        if type == .keyDown && keyCode == 6 && flags == .maskCommand {
            UserDictionaryStore.shared.cancelPendingFixes()
        }
        
        // ⌥⌘, from any app opens typ0s settings (the menu bar icon can hide behind the notch)
        if type == .keyDown && keyCode == 43 && flags == [.maskCommand, .maskAlternate] && state.isRecordingFor == nil {
            DispatchQueue.main.async { self.openSettingsWindow() }
            return nil
        }
        
        // 1. Recording a new hotkey: capture it as *pending* (user confirms with SAVE). Esc cancels.
        if type == .keyDown, state.isRecordingFor != nil {
            DispatchQueue.main.async {
                if keyCode == 53 && flags.isEmpty {
                    self.state.cancelRecording()
                } else {
                    self.state.capture(keyCode: keyCode, flags: flags)
                    if self.state.playSounds { NSSound(named: "Tink")?.play() }
                }
            }
            return nil
        }
        // Don't fire fixes while a pending key is waiting to be saved
        if state.pendingTarget != nil { return Unmanaged.passUnretained(event) }
        
        // 2. Double-Tap Right Shift (keyCode 60)
        if state.doubleTapRightShiftEnabled && type == .flagsChanged && keyCode == 60 && flags.contains(.maskShift) {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastRightShiftTime < 0.32 {
                lastRightShiftTime = 0
                DispatchQueue.main.async { self.fire(label: "⇧ ⇧") }
                return nil
            }
            lastRightShiftTime = now
        }
        
        // 3. Hotkeys. Auto: both profiles' hotkeys work, so any keyboard (or a mouse that reports
        //    itself as a keyboard) never leaves you with a hotkey you can't press. External / Built-in: only that one.
        if type == .keyDown {
            let mode = state.profileMode
            let externalOn = mode != .builtIn
            let builtInOn = mode != .external
            let isExternal = keyCode == state.nuphyKeyCode && flags == CGEventFlags(rawValue: state.nuphyFlagsRaw)
            // F5 also works on the NuPhy when the default F14 is set (only while an external keyboard is connected)
            let isNuPhyF5 = state.isNuPhyConnected && state.nuphyKeyCode == 107 && keyCode == 96 && flags.isEmpty
            let isBuiltIn = keyCode == state.macKeyCode && flags == CGEventFlags(rawValue: state.macFlagsRaw)
            if externalOn && (isExternal || isNuPhyF5) {
                let label = isNuPhyF5 ? "F5" : state.hotkeyLabel(keyCode, flags: flags, external: true)
                DispatchQueue.main.async { self.fire(label: label) }
                return nil
            }
            if builtInOn && isBuiltIn {
                let label = keyCodeToString(keyCode, flags: flags)
                DispatchQueue.main.async { self.fire(label: label) }
                return nil
            }
        }
        
        return Unmanaged.passUnretained(event)
    }
    
    /// Run a fix and remember which key started it, so the pill can show it (screen recorders can't see it:
    /// typ0s swallows the hotkey so it doesn't also type into your text)
    func fire(label: String) {
        state.lastTriggerLabel = label
        fixTextDirectly()
    }
    
    func flashPillSuccess(latencyMs: Double) {
        DispatchQueue.main.async {
            self.state.lastLatencyMs = latencyMs
            self.state.isFlashingSuccess = true
            if self.state.playSounds { NSSound(named: "Pop")?.play() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                self.state.isFlashingSuccess = false
            }
        }
    }
    
    // MARK: - Sub-5ms Direct In-Place Text Replacement
    func fixTextDirectly() {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        
        let t0 = CFAbsoluteTimeGetCurrent()
        
        // 1. Direct Native Accessibility API (0ms overhead, zero clipboard use!)
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        
        if err == .success, let focusedElement = focusedElementRef {
            let axElement = focusedElement as! AXUIElement
            
            // Case A: User highlighted text
            var selectedTextRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
               let selectedText = selectedTextRef as? String,
               !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                
                let fixed = engine.correctText(selectedText, learn: true)
                if AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, fixed as CFTypeRef) == .success {
                    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                    flashPillSuccess(latencyMs: ms)
                    return
                }
            }
            
            // Case B: Nothing highlighted -> automatically fix the entire text field in-place!
            var fullValueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &fullValueRef) == .success,
               let fullText = fullValueRef as? String,
               !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                
                let fixedFullText = engine.correctText(fullText, learn: true)
                if AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, fixedFullText as CFTypeRef) == .success {
                    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                    flashPillSuccess(latencyMs: ms)
                    return
                }
            }
        }
        
        // 2. Fallback for web/Electron apps that don't expose writable AXValueAttribute
        fastFallbackReplace(t0: t0)
    }
    
    func fastFallbackReplace(t0: CFAbsoluteTime) {
        DispatchQueue.global(qos: .userInteractive).async {
            let pasteboard = NSPasteboard.general
            let savedString = pasteboard.string(forType: .string)
            let initialCount = pasteboard.changeCount
            
            self.sendShortcut(keyCode: 8, flags: .maskCommand) // Cmd+C
            usleep(25_000)
            
            var targetText = ""
            if pasteboard.changeCount != initialCount, let str = pasteboard.string(forType: .string), !str.isEmpty {
                targetText = str
            } else {
                // Auto-select current paragraph up to cursor (Option + Shift + UpArrow)
                self.sendShortcut(keyCode: 126, flags: [.maskAlternate, .maskShift])
                usleep(20_000)
                let countAfterSelect = pasteboard.changeCount
                self.sendShortcut(keyCode: 8, flags: .maskCommand)
                usleep(25_000)
                if pasteboard.changeCount != countAfterSelect, let str = pasteboard.string(forType: .string) {
                    targetText = str
                }
            }
            
            guard !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if let old = savedString {
                    pasteboard.clearContents()
                    pasteboard.setString(old, forType: .string)
                }
                return
            }
            
            let corrected = self.engine.correctText(targetText, learn: true)
            pasteboard.clearContents()
            pasteboard.setString(corrected, forType: .string)
            self.sendShortcut(keyCode: 9, flags: .maskCommand) // Cmd+V
            usleep(35_000)
            
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            self.flashPillSuccess(latencyMs: ms)
            
            if let old = savedString {
                pasteboard.clearContents()
                pasteboard.setString(old, forType: .string)
            }
        }
    }
    
    func sendShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            keyDown.flags = flags
            keyUp.flags = flags
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }
}

@main
struct MainApp {
    static func main() {
        // build.sh runs `Typos --export-icon <file.png>` to draw the app icon, then exits
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-icon"), i + 1 < args.count {
            let ok = MainActor.assumeIsolated { LogoImages.writeAppIconPNG(to: args[i + 1]) }
            exit(ok ? 0 : 1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
