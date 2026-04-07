import AppKit
import GhosttyKit

/// Pure conversion helpers for translating between NSEvent and ghostty input types.
/// These are stateless functions — no dependency on MossSurfaceView instance state.
enum GhosttyInput {
    /// Build a ghostty key event from an NSEvent.
    /// - Parameter translationMods: If provided, used for consumed_mods calculation
    ///   instead of the event's own modifiers. This is needed for macos-option-as-alt:
    ///   when Option is translated away, consumed_mods must NOT include ALT, otherwise
    ///   ghostty thinks Alt was consumed and won't generate escape sequences.
    static func buildKeyEvent(
        _ event: NSEvent, action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode) // Raw macOS keyCode — NOT enum-mapped
        key.text = nil
        key.composing = false
        key.mods = mods(event.modifierFlags)
        key.consumed_mods = mods(
            (translationMods ?? event.modifierFlags).subtracting([.control, .command])
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

    /// Convert NSEvent modifier flags to ghostty modifier bitmask.
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }

        // Right-side modifier detection via device-specific masks.
        // Needed for macos-option-as-alt = left|right to work correctly.
        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { raw |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { raw |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { raw |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { raw |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(raw)
    }

    /// Convert ghostty translated mods back to NSEvent.ModifierFlags,
    /// preserving non-modifier bits from the original flags.
    static func applyTranslatedMods(
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

    /// Extract printable characters from an NSEvent for ghostty,
    /// filtering out control characters and function-key Unicode range.
    static func characters(from event: NSEvent) -> String? {
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

    /// Determine if a flagsChanged event is a press or release.
    static func isFlagPress(_ event: NSEvent) -> Bool {
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

    /// Check if an event is Cmd+V (paste).
    static func isPasteKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "v"
    }
}
