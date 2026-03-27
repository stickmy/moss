import AppKit
import GhosttyKit

// MARK: - Delegate Protocol

@MainActor
protocol MossSurfaceViewDelegate: AnyObject {
    func surfaceDidChangeTitle(_ title: String)
    func surfaceDidChangePwd(_ pwd: String)
    func surfaceDidChangeFocus(_ focused: Bool)
    func surfaceDidRequestDesktopNotification(title: String, body: String)
    func surfaceDidAcknowledgePendingAttention()
    func surfaceDidClose(processAlive: Bool)
}

// MARK: - MossSurfaceView

/// Custom NSView that directly manages a ghostty surface, CAMetalLayer,
/// display link, keyboard/mouse input, and IME — replacing the layered
/// TerminalView + KeyInputView architecture.
@MainActor
final class MossSurfaceView: NSView, NSTextInputClient {
    // Surface state
    private let terminalApp: MossTerminalApp
    private var surface: ghostty_surface_t?
    private var bridge: MossSurfaceBridge?
    private var metalLayer: CAMetalLayer?
    private var lastContentScale: Double?
    private var lastFramebufferSize: (width: UInt32, height: UInt32)?

    // Display link
    private var displayLink: CVDisplayLink?
    private let displayLinkTarget = DisplayLinkTarget()
    private let needsTick = NeedsTick()

    // Input state
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?

    // Session linkage
    weak var delegate: MossSurfaceViewDelegate?
    var sessionId: UUID?

    // Active state (false when hidden in grid)
    var isActive: Bool = true {
        didSet {
            guard isActive != oldValue else { return }

            if isActive {
                isHidden = false
                if window != nil {
                    startDisplayLink()
                    tick()
                }
            } else {
                stopDisplayLink()
                isHidden = true
                if window?.firstResponder === self {
                    window?.makeFirstResponder(nil)
                }
            }
        }
    }

    // Focus-click suppression: when a click is only to focus this terminal,
    // don't forward it to ghostty (prevents phantom selection).
    private var focusClickSuppressed = false

    // Configuration
    private let workingDirectory: String?
    private let socketPath: String?

    init(
        terminalApp: MossTerminalApp,
        sessionId: UUID,
        workingDirectory: String? = nil,
        socketPath: String? = nil
    ) {
        self.terminalApp = terminalApp
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.socketPath = socketPath
        super.init(frame: .zero)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    // MARK: - Setup

    private func commonInit() {
        wantsLayer = true
        focusRingType = .none

        let metal = CAMetalLayer()
        metal.device = MTLCreateSystemDefaultDevice()
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metal.isOpaque = false
        metal.backgroundColor = NSColor.clear.cgColor
        layer = metal
        metalLayer = metal

        setupTrackingArea()
    }

    // MARK: - Surface Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && surface == nil {
            createSurface()
            if isActive {
                startDisplayLink()
            }
        } else if window == nil {
            stopDisplayLink()
        }
    }

    override func layout() {
        super.layout()
        synchronizeMetalLayerFrame()
        synchronizeMetrics()
    }

    private func createSurface() {
        guard let app = terminalApp.app else { return }

        let surfaceBridge = MossSurfaceBridge(view: self)
        self.bridge = surfaceBridge

        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(surfaceBridge).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        config.scale_factor = Double(
            window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        )
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        config.wait_after_command = false

        let shellCommand = terminalApp.surfaceShellCommand()
        let resourcesPath = terminalApp.embeddedResourcesPath

        var envPairs: [(String, String)] = [
            ("MOSS_SOCKET_PATH", socketPath ?? ""),
            ("MOSS_SURFACE_ID", sessionId?.uuidString ?? ""),
            ("MOSS_CLI_PATH", Self.resolveMossCLIPath() ?? ""),
        ]

        if let resourcesPath, !resourcesPath.isEmpty {
            envPairs.append(("GHOSTTY_RESOURCES_DIR", resourcesPath))
        }

        if let shellCommand,
           URL(fileURLWithPath: shellCommand).lastPathComponent == "zsh",
           let resourcesPath,
           !resourcesPath.isEmpty
        {
            let zshDotdir = URL(fileURLWithPath: resourcesPath)
                .appendingPathComponent("shell-integration/zsh")
                .path
            envPairs.append(("ZDOTDIR", zshDotdir))

            if let existingZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"],
               !existingZdotdir.isEmpty
            {
                envPairs.append(("GHOSTTY_ZSH_ZDOTDIR", existingZdotdir))
            }
        }

        // Per-surface environment variables via ghostty_surface_config_s.env_vars
        let allocatedEnvPairs = envPairs.map { (strdup($0.0)!, strdup($0.1)!) }
        defer {
            for (key, value) in allocatedEnvPairs {
                free(key)
                free(value)
            }
        }

        var envVars = allocatedEnvPairs.map { key, value in
            ghostty_env_var_s(key: key, value: value)
        }

        envVars.withUnsafeMutableBufferPointer { envBuffer in
            config.env_vars = envBuffer.baseAddress
            config.env_var_count = envBuffer.count

            let createGhosttySurface = { [self] in
                if let workingDirectory = self.workingDirectory {
                    workingDirectory.withCString { wd in
                        config.working_directory = wd
                        self.surface = ghostty_surface_new(app, &config)
                    }
                } else {
                    self.surface = ghostty_surface_new(app, &config)
                }
            }

            if let shellCommand {
                shellCommand.withCString { command in
                    config.command = command
                    createGhosttySurface()
                }
            } else {
                createGhosttySurface()
            }
        }

        if let surface {
            lastContentScale = nil
            lastFramebufferSize = nil
            surfaceBridge.rawSurface = surface
            terminalApp.retain(surfaceBridge)
            synchronizeMetrics()
        }
    }

    private func synchronizeMetalLayerFrame() {
        guard let metalLayer, metalLayer.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        CATransaction.commit()
    }

    private static func resolveMossCLIPath() -> String? {
        let fm = FileManager.default

        if let override = ProcessInfo.processInfo.environment["MOSS_CLI_PATH"],
           fm.isExecutableFile(atPath: override)
        {
            return override
        }

        let bundleCandidates: [String?] = [
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("moss")
                .path,
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("moss")
                .path,
            Bundle.main.sharedSupportURL?
                .appendingPathComponent("moss")
                .path,
        ]

        for candidate in bundleCandidates.compactMap({ $0 }) {
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private func synchronizeMetrics() {
        guard let surface else { return }
        let scale = Double(
            window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        )
        guard bounds.width > 0, bounds.height > 0 else { return }

        let pixelW = UInt32((bounds.width * scale).rounded(.down))
        let pixelH = UInt32((bounds.height * scale).rounded(.down))
        guard pixelW > 0, pixelH > 0 else { return }

        if lastContentScale != scale {
            ghostty_surface_set_content_scale(surface, scale, scale)
            lastContentScale = scale
        }

        let framebufferSize = (width: pixelW, height: pixelH)
        if lastFramebufferSize?.width != framebufferSize.width
            || lastFramebufferSize?.height != framebufferSize.height
        {
            ghostty_surface_set_size(surface, pixelW, pixelH)
            lastFramebufferSize = framebufferSize
        }
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        displayLinkTarget.view = self

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let tick = needsTick
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userdata -> CVReturn in
            guard let userdata else { return kCVReturnSuccess }
            let tick = Unmanaged<NeedsTick>.fromOpaque(userdata).takeUnretainedValue()
            // Coalesce: only dispatch if previous tick has completed
            if tick.swap() {
                DispatchQueue.main.async {
                    tick.target?.tick()
                    tick.clear()
                }
            }
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(tick).toOpaque())
        tick.target = displayLinkTarget
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        displayLink = nil
        displayLinkTarget.view = nil
    }

    func tick() {
        guard isActive else { return }
        terminalApp.tick()
        guard let surface else { return }
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        enforceMetalLayerScale()
    }

    private func enforceMetalLayerScale() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if metalLayer.contentsScale != scale {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.contentsScale = scale
            CATransaction.commit()
        }
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { isActive }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, true) }
        delegate?.surfaceDidChangeFocus(true)
        // Notify ContentView immediately so file tree updates reliably
        if let sessionId {
            NotificationCenter.default.post(
                name: .terminalFocusChanged,
                object: nil,
                userInfo: ["sessionId": sessionId]
            )
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        // Reset stale focus-click state (same fix as ghostty PR #11276)
        focusClickSuppressed = false
        if let surface {
            ghostty_surface_mouse_button(
                surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT,
                ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
            )
            ghostty_surface_set_focus(surface, false)
        }
        delegate?.surfaceDidChangeFocus(false)
        return result
    }

    // MARK: - Key Events

    /// Handle key events that need priority over the responder chain.
    /// Ghostty keybindings are checked first via ghostty_surface_key_is_binding.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }

        // App-level shortcuts work regardless of focus
        if event.modifierFlags.contains(.command) {
            if event.keyCode == 0x24, event.modifierFlags.contains(.shift) {
                NotificationCenter.default.post(name: .terminalToggleZoom, object: nil)
                return true
            }
            if event.keyCode == 0x2D, !event.modifierFlags.contains(.shift) {
                NotificationCenter.default.post(name: .terminalNewRequested, object: nil)
                return true
            }
            if event.keyCode == 0x0B, !event.modifierFlags.contains(.shift) {
                NotificationCenter.default.post(name: .terminalToggleFileTree, object: nil)
                return true
            }
        }

        // Only the focused surface should handle input
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        guard let surface else { return super.performKeyEquivalent(with: event) }

        // Check if this key event matches a ghostty keybinding
        var ghosttyEvent = buildKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
        let isBinding: Bool = (event.characters ?? "").withCString { ptr in
            ghosttyEvent.text = ptr
            var flags = ghostty_binding_flags_e(0)
            let result = ghostty_surface_key_is_binding(surface, ghosttyEvent, &flags)
            return result
        }

        if isBinding {
            if isPasteKeyEquivalent(event) {
                acknowledgePendingAttention()
            }
            // Send directly to ghostty to execute the binding
            var key = buildKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
            let chars = event.characters ?? ""
            if !chars.isEmpty, let cp = chars.utf8.first, cp >= 0x20 {
                chars.withCString { ptr in
                    key.text = ptr
                    _ = ghostty_surface_key(surface, key)
                }
            } else {
                _ = ghostty_surface_key(surface, key)
            }
            return true
        }

        // Non-binding Cmd combos → send to ghostty (paste, copy, etc.)
        if event.modifierFlags.contains(.command) {
            if isPasteKeyEquivalent(event) {
                acknowledgePendingAttention()
            }
            var key = buildKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
            key.text = nil
            return ghostty_surface_key(surface, key)
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }

        // Cmd combos are handled by performKeyEquivalent
        if event.modifierFlags.contains(.command) { return }

        acknowledgePendingAttention()

        let action: ghostty_input_action_e =
            event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Apply macos-option-as-alt translation from ghostty config
        let translatedMods = ghostty_surface_key_translation_mods(
            surface, ghosttyMods(event.modifierFlags)
        )
        let translatedFlags = applyTranslatedMods(
            original: event.modifierFlags,
            translated: translatedMods
        )

        // If mods changed (e.g. option-as-alt), create a new event for interpretKeyEvents
        let translationEvent: NSEvent
        if translatedFlags == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translatedFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translatedFlags) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let markedBefore = markedText.length > 0

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([translationEvent])

        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count))
            }
        } else if markedBefore {
            ghostty_surface_preedit(surface, nil, 0)
        }

        if let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts {
                var key = buildKeyEvent(event, action: action)
                text.withCString { ptr in
                    key.text = ptr
                    _ = ghostty_surface_key(surface, key)
                }
            }
        } else {
            var key = buildKeyEvent(event, action: action)
            let text = ghosttyCharacters(from: translationEvent)
            key.composing = markedText.length > 0 || markedBefore

            if let text, !text.isEmpty,
               let codepoint = text.utf8.first, codepoint >= 0x20
            {
                text.withCString { ptr in
                    key.text = ptr
                    _ = ghostty_surface_key(surface, key)
                }
            } else {
                key.text = nil
                _ = ghostty_surface_key(surface, key)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var key = buildKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
        key.text = nil
        _ = ghostty_surface_key(surface, key)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        let isPress = isFlagPress(event)
        var key = buildKeyEvent(
            event, action: isPress ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        )
        key.text = nil
        _ = ghostty_surface_key(surface, key)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let wasFocused = window?.firstResponder === self
        window?.makeFirstResponder(self)

        // If this click was just to focus the terminal, don't send to ghostty
        if !wasFocused {
            focusClickSuppressed = true
            return
        }

        guard let surface else { return }
        let pos = convertToSurface(event.locationInWindow)
        ghostty_surface_mouse_pos(surface, pos.x, pos.y, ghosttyMods(event.modifierFlags))
        ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT,
            ghosttyMods(event.modifierFlags)
        )
    }

    override func mouseUp(with event: NSEvent) {
        if focusClickSuppressed {
            focusClickSuppressed = false
            return
        }
        guard let surface else { return }
        let pos = convertToSurface(event.locationInWindow)
        ghostty_surface_mouse_pos(surface, pos.x, pos.y, ghosttyMods(event.modifierFlags))
        ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT,
            ghosttyMods(event.modifierFlags)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        if focusClickSuppressed { return }
        guard let surface else { return }
        let pos = convertToSurface(event.locationInWindow)
        ghostty_surface_mouse_pos(surface, pos.x, pos.y, ghosttyMods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface, window?.firstResponder === self else { return }
        let pos = convertToSurface(event.locationInWindow)
        ghostty_surface_mouse_pos(surface, pos.x, pos.y, ghosttyMods(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let pos = convertToSurface(event.locationInWindow)
        ghostty_surface_mouse_pos(surface, pos.x, pos.y, ghosttyMods(event.modifierFlags))
        let consumed = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT,
            ghosttyMods(event.modifierFlags)
        )
        if !consumed {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let pos = convertToSurface(event.locationInWindow)
        ghostty_surface_mouse_pos(surface, pos.x, pos.y, ghosttyMods(event.modifierFlags))
        ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT,
            ghosttyMods(event.modifierFlags)
        )
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface, window?.firstResponder === self else { return }
        let pos = convertToSurface(event.locationInWindow)
        ghostty_surface_mouse_pos(surface, pos.x, pos.y, ghosttyMods(event.modifierFlags))

        // ghostty_input_scroll_mods_t is Int32 packed bitmask:
        // bit 0 = precision, bits 1-3 = momentum phase
        var scrollMods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas {
            scrollMods |= 0b0000_0001
        }
        ghostty_surface_mouse_scroll(
            surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollMods
        )
    }

    private func convertToSurface(_ windowPoint: NSPoint) -> NSPoint {
        let local = convert(windowPoint, from: nil)
        // ghostty: (0,0) at top-left; AppKit: (0,0) at bottom-left
        return NSPoint(x: local.x, y: bounds.height - local.y)
    }

    // MARK: - Tracking Area

    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    // MARK: - Key Event Construction

    private func buildKeyEvent(
        _ event: NSEvent, action: ghostty_input_action_e
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode) // Raw macOS keyCode — NOT enum-mapped
        key.text = nil
        key.composing = false
        key.mods = ghosttyMods(event.modifierFlags)
        key.consumed_mods = ghosttyMods(
            event.modifierFlags.subtracting([.control, .command])
        )
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let cp = chars.unicodeScalars.first
            {
                key.unshifted_codepoint = cp.value
            }
        }
        return key
    }

    private func ghosttyCharacters(from event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(
                    byApplyingModifiers: event.modifierFlags.subtracting(.control)
                )
            }
            if scalar.value >= 0xF700, scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }

    private func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    /// Convert ghostty translated mods back to NSEvent.ModifierFlags,
    /// preserving non-modifier bits from the original flags.
    private func applyTranslatedMods(
        original: NSEvent.ModifierFlags,
        translated: ghostty_input_mods_e
    ) -> NSEvent.ModifierFlags {
        var result = original
        let raw = translated.rawValue
        for (flag, ghosttyMod) in [
            (NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT),
            (.control, GHOSTTY_MODS_CTRL),
            (.option, GHOSTTY_MODS_ALT),
            (.command, GHOSTTY_MODS_SUPER),
        ] as [(NSEvent.ModifierFlags, ghostty_input_mods_e)] {
            if raw & ghosttyMod.rawValue != 0 {
                result.insert(flag)
            } else {
                result.remove(flag)
            }
        }
        return result
    }

    private func isFlagPress(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch event.keyCode {
        case 56, 60: return flags.contains(.shift)
        case 58, 61: return flags.contains(.option)
        case 59, 62: return flags.contains(.control)
        case 55, 54: return flags.contains(.command)
        case 57: return flags.contains(.capsLock)
        default: return false
        }
    }

    private func isPasteKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    private func acknowledgePendingAttention() {
        delegate?.surfaceDidAcknowledgePendingAttention()
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func setMarkedText(
        _ string: Any, selectedRange _: NSRange, replacementRange _: NSRange
    ) {
        switch string {
        case let s as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: s)
        case let s as String:
            markedText = NSMutableAttributedString(string: s)
        default: break
        }
    }

    func unmarkText() {
        markedText.mutableString.setString("")
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(
        forProposedRange _: NSRange, actualRange _: NSRangePointer?
    ) -> NSAttributedString? { nil }

    func insertText(_ string: Any, replacementRange _: NSRange) {
        var chars = ""
        switch string {
        case let s as NSAttributedString: chars = s.string
        case let s as String: chars = s
        default: return
        }
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
        } else if let surface {
            chars.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(chars.utf8.count))
            }
        }
    }

    @IBAction func paste(_ sender: Any?) {
        guard let surface, window?.firstResponder === self else { return }

        acknowledgePendingAttention()
        let action = "paste_from_clipboard"
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    @IBAction func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }

    func characterIndex(for _: NSPoint) -> Int { 0 }

    func firstRect(
        forCharacterRange _: NSRange, actualRange _: NSRangePointer?
    ) -> NSRect {
        guard let surface, let window else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let localRect = NSRect(x: x, y: bounds.height - y - h, width: w, height: h)
        let windowRect = convert(localRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    // MARK: - Action Handling (from C callbacks)

    func handleAction(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let notification = action.action.desktop_notification
            let title = notification.title.map { String(cString: $0) } ?? ""
            let body = notification.body.map { String(cString: $0) } ?? ""
            delegate?.surfaceDidRequestDesktopNotification(title: title, body: body)
        case GHOSTTY_ACTION_SET_TITLE:
            if let cStr = action.action.set_title.title {
                delegate?.surfaceDidChangeTitle(String(cString: cStr))
            }
        case GHOSTTY_ACTION_PWD:
            if let cStr = action.action.pwd.pwd {
                delegate?.surfaceDidChangePwd(String(cString: cStr))
            }
        case GHOSTTY_ACTION_NEW_SPLIT:
            // Moss maps split creation to a new free-positioned terminal card.
            NotificationCenter.default.post(name: .terminalNewRequested, object: nil)
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            NotificationCenter.default.post(name: .terminalToggleZoom, object: nil)
        case GHOSTTY_ACTION_NEW_TAB:
            NotificationCenter.default.post(name: .terminalNewRequested, object: nil)
        case GHOSTTY_ACTION_NEW_WINDOW:
            NotificationCenter.default.post(name: .terminalNewRequested, object: nil)
        default:
            break
        }
    }

    func handleClose(processAlive: Bool) {
        delegate?.surfaceDidClose(processAlive: processAlive)
    }

    // MARK: - Cleanup

    func freeSurface() {
        stopDisplayLink()
        if let surface {
            ghostty_surface_set_focus(surface, false)
            ghostty_surface_free(surface)
        }
        surface = nil
        if let bridge {
            terminalApp.remove(bridge)
        }
        bridge = nil
        lastContentScale = nil
        lastFramebufferSize = nil
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let terminalDidFocus = Notification.Name("terminalDidFocus")
    static let terminalToggleZoom = Notification.Name("terminalToggleZoom")
    static let terminalNewRequested = Notification.Name("terminalNewRequested")
    static let terminalToggleFileTree = Notification.Name("terminalToggleFileTree")
    static let terminalFocusChanged = Notification.Name("terminalFocusChanged")
}

// MARK: - DisplayLinkTarget

/// Weak-referencing bridge for CVDisplayLink callback safety.
private final class DisplayLinkTarget: @unchecked Sendable {
    @MainActor weak var view: MossSurfaceView?

    func tick() {
        MainActor.assumeIsolated {
            view?.tick()
        }
    }
}

/// Prevents display link from flooding the main queue with async blocks.
/// Only one tick is dispatched at a time; intervening frames are skipped.
private final class NeedsTick: @unchecked Sendable {
    private var pending: Int32 = 0
    weak var target: DisplayLinkTarget?

    /// Returns true if this is the first request (should dispatch).
    func swap() -> Bool {
        OSAtomicCompareAndSwap32(0, 1, &pending)
    }

    func clear() {
        OSAtomicCompareAndSwap32(1, 0, &pending)
    }
}

extension MossSurfaceView {
    var snapshotImage: NSImage? {
        guard !bounds.isEmpty,
              let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds)
        else {
            return nil
        }

        cacheDisplay(in: bounds, to: bitmapRep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }
}
