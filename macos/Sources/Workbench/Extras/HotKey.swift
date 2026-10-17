import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// A system-wide shortcut that brings Workbench forward from any app. It uses the system's hot key
/// registration, which needs no Accessibility permission. ⌃⌥⌘W unless changed in Settings.
@MainActor
enum GlobalShortcut {
  struct Combo: Equatable {
    /// A virtual key code (kVK_…) and Carbon modifier flags (cmdKey, optionKey, …).
    let keyCode: UInt32
    let modifiers: UInt32
    /// How it reads in menus: "⌃⌥⌘W".
    let display: String

    static let standard = Combo(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘W")
  }

  private static let defaults = UserDefaults.standard
  private static var hotKey: EventHotKeyRef?
  private static var handler: EventHandlerRef?

  static var isEnabled: Bool {
    get { defaults.object(forKey: "shortcut.enabled") as? Bool ?? true }
    set {
      defaults.set(newValue, forKey: "shortcut.enabled")
      apply()
    }
  }

  static var combo: Combo {
    get {
      guard let display = defaults.string(forKey: "shortcut.display") else { return .standard }
      return Combo(keyCode: UInt32(defaults.integer(forKey: "shortcut.keyCode")), modifiers: UInt32(defaults.integer(forKey: "shortcut.modifiers")), display: display)
    }
    set {
      defaults.set(Int(newValue.keyCode), forKey: "shortcut.keyCode")
      defaults.set(Int(newValue.modifiers), forKey: "shortcut.modifiers")
      defaults.set(newValue.display, forKey: "shortcut.display")
      apply()
    }
  }

  /// Registers the shortcut (again), or removes it when turned off.
  static func apply() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    hotKey = nil
    guard isEnabled else { return }
    if handler == nil {
      var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { AppState.shared.show() } }
        return noErr
      }, 1, &spec, nil, &handler)
    }
    let id = EventHotKeyID(signature: OSType(0x574B_424E) /* "WKBN" */, id: 1)
    let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    // Another app already holding the same keys is the usual reason.
    if status != noErr { log.error("Couldn't register the shortcut \(combo.display, privacy: .public): \(status)") }
  }

  /// The combo a key press makes, if it has a modifier besides Shift (a bare key would steal typing).
  static func combo(from event: NSEvent) -> Combo? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard !flags.intersection([.command, .control, .option]).isEmpty, let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
    var modifiers: UInt32 = 0
    var display = ""
    if flags.contains(.control) { modifiers |= UInt32(controlKey); display += "⌃" }
    if flags.contains(.option) { modifiers |= UInt32(optionKey); display += "⌥" }
    if flags.contains(.shift) { modifiers |= UInt32(shiftKey); display += "⇧" }
    if flags.contains(.command) { modifiers |= UInt32(cmdKey); display += "⌘" }
    let name = switch Int(event.keyCode) {
    case kVK_Space: "Space"
    case kVK_Return: "↩"
    case kVK_Tab: "⇥"
    default: key
    }
    return Combo(keyCode: UInt32(event.keyCode), modifiers: modifiers, display: display + name)
  }
}

/// Open at login, through macOS's login items (System Settings → General → Login Items).
@MainActor
enum LoginItem {
  static var status: SMAppService.Status { SMAppService.mainApp.status }

  static func set(_ on: Bool) throws {
    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
  }

  static func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
