import AppKit
import Carbon.HIToolbox
import Foundation

struct LegacyKeyboardShortcut: Codable {
    let carbonKeyCode: Int
    let carbonModifiers: Int
}

struct ShortcutBackup: Codable {
    let shortcut: Shortcut

    init(_ shortcut: Shortcut) {
        self.shortcut = shortcut
    }

    init(from decoder: Decoder) throws {
        if let shortcut = try? Shortcut(from: decoder) {
            self.shortcut = shortcut
            return
        }

        let legacyShortcut = try LegacyKeyboardShortcut(from: decoder)
        self.shortcut = Shortcut.fromLegacyShortcut(legacyShortcut)
    }

    func encode(to encoder: Encoder) throws {
        try shortcut.encode(to: encoder)
    }
}

enum ShortcutMigration {
    static func migrateLegacyShortcutsIfNeeded() {
        migrateLegacyCustomRecordingShortcutsIfNeeded()
        migrateLegacyKeyboardShortcutsIfNeeded()
    }

    static func migrateLegacyKeyboardShortcutsIfNeeded() {
        let migrationKey = "ShortcutManager_LegacyKeyboardShortcutsMigrated"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        for action in ShortcutAction.legacyStaticActions {
            migrateLegacyKeyboardShortcut(for: action)
        }

        for config in PowerModeManager.shared.configurations {
            migrateLegacyKeyboardShortcut(for: .powerMode(config.id))
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    static func shortcutSelection(
        forKey userDefaultsKey: String,
        action: ShortcutAction,
        allowsNone: Bool
    ) -> HotkeyManager.HotkeyOption {
        guard
            let storedValue = UserDefaults.standard.string(forKey: userDefaultsKey),
            !storedValue.isEmpty
        else {
            if !allowsNone {
                migrateDefaultPrimaryShortcutIfNeeded(for: action)
                UserDefaults.standard.set(HotkeyManager.HotkeyOption.custom.rawValue, forKey: userDefaultsKey)
                return .custom
            }

            return .none
        }

        if storedValue == HotkeyManager.HotkeyOption.custom.rawValue {
            return .custom
        }

        if storedValue == HotkeyManager.HotkeyOption.none.rawValue {
            return allowsNone ? .none : .custom
        }

        if let shortcut = legacyPresetShortcut(for: storedValue) {
            if ShortcutStore.shortcut(for: action) == nil {
                ShortcutStore.setShortcut(shortcut, for: action)
            }

            UserDefaults.standard.set(HotkeyManager.HotkeyOption.custom.rawValue, forKey: userDefaultsKey)
            return .custom
        }

        return allowsNone ? .none : .custom
    }

    static func removeLegacyCustomRecordingShortcut(for action: ShortcutAction) {
        UserDefaults.standard.removeObject(forKey: legacyCustomRecordingShortcutKey(for: action))
    }

    static func removeLegacyKeyboardShortcut(for action: ShortcutAction) {
        guard let legacyName = legacyKeyboardShortcutsName(for: action) else {
            return
        }

        UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_\(legacyName)")
    }

    static func migrateLegacyKeyboardShortcut(for action: ShortcutAction) {
        guard
            ShortcutStore.storedShortcut(for: action) == nil,
            !ShortcutStore.isShortcutCleared(for: action),
            let shortcut = legacyKeyboardShortcut(for: action)
        else {
            return
        }

        ShortcutStore.setShortcut(shortcut, for: action)
    }

    private static func migrateLegacyCustomRecordingShortcutsIfNeeded() {
        let migrationKey = "ShortcutManager_LegacyCustomRecordingShortcutsMigrated"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        for action in [ShortcutAction.primaryRecording, .secondaryRecording] {
            migrateLegacyCustomRecordingShortcut(for: action)
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    private static func migrateLegacyCustomRecordingShortcut(for action: ShortcutAction) {
        guard
            ShortcutStore.storedShortcut(for: action) == nil,
            !ShortcutStore.isShortcutCleared(for: action),
            let data = UserDefaults.standard.data(forKey: legacyCustomRecordingShortcutKey(for: action)),
            let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data)
        else {
            return
        }

        ShortcutStore.setShortcut(shortcut, for: action)
    }

    private static func migrateDefaultPrimaryShortcutIfNeeded(for action: ShortcutAction) {
        guard
            action == .primaryRecording,
            ShortcutStore.shortcut(for: action) == nil,
            let shortcut = legacyPresetShortcut(for: "rightCommand")
        else {
            return
        }

        ShortcutStore.setShortcut(shortcut, for: action)
    }

    private static func legacyPresetShortcut(for rawValue: String) -> Shortcut? {
        switch rawValue {
        case "rightOption":
            return .modifierOnly(keyCode: UInt16(kVK_RightOption), modifierFlags: [.option])
        case "leftOption":
            return .modifierOnly(keyCode: UInt16(kVK_Option), modifierFlags: [.option])
        case "leftControl":
            return .modifierOnly(keyCode: UInt16(kVK_Control), modifierFlags: [.control])
        case "rightControl":
            return .modifierOnly(keyCode: UInt16(kVK_RightControl), modifierFlags: [.control])
        case "fn":
            return .modifierOnly(keyCode: UInt16(kVK_Function), modifierFlags: [.function])
        case "rightCommand":
            return .modifierOnly(keyCode: UInt16(kVK_RightCommand), modifierFlags: [.command])
        case "rightShift":
            return .modifierOnly(keyCode: UInt16(kVK_RightShift), modifierFlags: [.shift])
        default:
            return nil
        }
    }

    private static func legacyCustomRecordingShortcutKey(for action: ShortcutAction) -> String {
        "CustomRecordingShortcut_\(action.storageName)"
    }

    private static func legacyKeyboardShortcut(for action: ShortcutAction) -> Shortcut? {
        guard
            let legacyName = legacyKeyboardShortcutsName(for: action),
            let data = UserDefaults.standard.string(forKey: "KeyboardShortcuts_\(legacyName)")?.data(using: .utf8),
            let legacyShortcut = try? JSONDecoder().decode(LegacyKeyboardShortcut.self, from: data)
        else {
            return nil
        }

        return Shortcut.fromLegacyShortcut(legacyShortcut)
    }

    private static func legacyKeyboardShortcutsName(for action: ShortcutAction) -> String? {
        switch action {
        case .primaryRecording:
            return "toggleMiniRecorder"
        case .secondaryRecording:
            return "toggleMiniRecorder2"
        case .pasteLastTranscription:
            return "pasteLastTranscription"
        case .pasteLastEnhancement:
            return "pasteLastEnhancement"
        case .retryLastTranscription:
            return "retryLastTranscription"
        case .cancelRecorder:
            return "cancelRecorder"
        case .openHistoryWindow:
            return "openHistoryWindow"
        case .quickAddToDictionary:
            return "quickAddToDictionary"
        case .toggleEnhancement:
            return "toggleEnhancement"
        case .powerMode(let id):
            return "powerMode_\(id.uuidString)"
        case .miniRecorderEscape, .miniRecorderPrompt, .miniRecorderPowerMode:
            return nil
        }
    }
}
