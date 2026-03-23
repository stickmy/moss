import Foundation
import GhosttyKit
import AppKit
import Darwin

/// Manages the ghostty app lifecycle directly via the C API.
/// Replaces TerminalController from libghostty-spm for full control
/// over surface creation, callbacks, and input handling.
@MainActor
final class MossTerminalApp {
    nonisolated(unsafe) var app: ghostty_app_t?
    private nonisolated(unsafe) var config: ghostty_config_t?
    var retainedBridges: [MossSurfaceBridge] = []
    private(set) var theme: MossTheme!
    private(set) var explicitCommandOverride: String?
    private(set) var embeddedResourcesPath: String?

    init() {
        ghostty_init(0, nil)
        installEmbeddedResourceHints()
        setupConfig()
        theme = MossTheme(config: config)
        createApp()
    }

    func surfaceShellCommand() -> String? {
        if let explicitCommandOverride, !explicitCommandOverride.isEmpty {
            return explicitCommandOverride
        }

        if let shell = loginShellFromPasswd() {
            return shell
        }

        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }

        return nil
    }

    private func setupConfig() {
        guard let cfg = ghostty_config_new() else { return }

        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        explicitCommandOverride = configStringValue("command", from: cfg)

        config = cfg
    }

    private func createApp() {
        guard let cfg = config else { return }

        let userdata = Unmanaged.passUnretained(self).toOpaque()

        var rc = ghostty_runtime_config_s()
        rc.userdata = userdata
        rc.supports_selection_clipboard = false
        rc.wakeup_cb = mossWakeupCallback
        rc.action_cb = mossActionCallback
        rc.close_surface_cb = mossCloseSurfaceCallback
        rc.write_clipboard_cb = mossWriteClipboardCallback
        rc.read_clipboard_cb = mossReadClipboardCallback

        app = ghostty_app_new(&rc, cfg)
    }

    private func installEmbeddedResourceHints() {
        guard let resourceURL = Bundle.main.resourceURL else { return }

        let ghosttyResources = resourceURL
            .appendingPathComponent("ghostty")
            .path

        embeddedResourcesPath = ghosttyResources
        setenv("GHOSTTY_RESOURCES_DIR", ghosttyResources, 1)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func retain(_ bridge: MossSurfaceBridge) {
        retainedBridges.append(bridge)
    }

    func remove(_ bridge: MossSurfaceBridge) {
        retainedBridges.removeAll { $0 === bridge }
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    private func configStringValue(_ key: String, from cfg: ghostty_config_t) -> String? {
        var value: UnsafePointer<Int8>?
        guard ghostty_config_get(cfg, &value, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return nil
        }

        guard let value else { return nil }
        return String(cString: value)
    }

    private func loginShellFromPasswd() -> String? {
        guard let entry = getpwuid(getuid()),
              let shellPtr = entry.pointee.pw_shell
        else {
            return nil
        }

        let shell = String(cString: shellPtr)
        return shell.isEmpty ? nil : shell
    }
}

// MARK: - Surface Callback Bridge

/// Passed as userdata for each ghostty surface.
/// Routes C callbacks back to the owning MossSurfaceView.
final class MossSurfaceBridge: @unchecked Sendable {
    @MainActor weak var view: MossSurfaceView?
    nonisolated(unsafe) var rawSurface: ghostty_surface_t?

    @MainActor init(view: MossSurfaceView) {
        self.view = view
    }
}

// MARK: - C Callbacks

private func mossWakeupCallback(userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let app = Unmanaged<MossTerminalApp>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        app.tick()
    }
}

private func mossActionCallback(
    appPtr: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool {
    guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
    guard let surfacePtr = target.target.surface else { return false }
    guard let bridgePtr = ghostty_surface_userdata(surfacePtr) else { return false }

    let bridge = Unmanaged<MossSurfaceBridge>.fromOpaque(bridgePtr).takeUnretainedValue()
    DispatchQueue.main.async {
        bridge.view?.handleAction(action)
    }
    return false
}

private func mossCloseSurfaceCallback(
    userdata: UnsafeMutableRawPointer?,
    processAlive: Bool
) {
    guard let userdata else { return }
    let bridge = Unmanaged<MossSurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        bridge.view?.handleClose(processAlive: processAlive)
    }
}

private func mossWriteClipboardCallback(
    userdata _: UnsafeMutableRawPointer?,
    clipboard _: ghostty_clipboard_e,
    contents: UnsafePointer<ghostty_clipboard_content_s>?,
    contentsLen: Int,
    confirm _: Bool
) {
    guard contentsLen > 0 else { return }
    guard let content = contents?.pointee else { return }
    guard let data = content.data else { return }
    let string = String(cString: data)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
}

private func mossReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard _: ghostty_clipboard_e,
    opaquePtr: UnsafeMutableRawPointer?
) -> Bool {
    guard let userdata, let opaquePtr else { return false }
    let bridge = Unmanaged<MossSurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
    guard let surface = bridge.rawSurface else { return false }
    guard let string = NSPasteboard.general.string(forType: .string) else { return false }
    string.withCString { cString in
        ghostty_surface_complete_clipboard_request(surface, cString, opaquePtr, true)
    }
    return true
}
