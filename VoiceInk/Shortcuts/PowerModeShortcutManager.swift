import Foundation

@MainActor
class PowerModeShortcutManager {
    private weak var engine: VoiceInkEngine?
    private let shortcutMonitor = ShortcutMonitor()
    private var shortcutChangeObserver: NSObjectProtocol?

    init(engine: VoiceInkEngine) {
        self.engine = engine

        setupPowerModeHotkeys()

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let action = notification.object as? ShortcutAction,
                case .powerMode = action
            else {
                return
            }

            Task { @MainActor in
                self?.setupPowerModeHotkeys()
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerModeShortcutAvailabilityDidChange),
            name: .powerModeShortcutAvailabilityDidChange,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }
        MainActor.assumeIsolated {
            shortcutMonitor.stop()
        }
    }

    @objc private func powerModeShortcutAvailabilityDidChange() {
        Task { @MainActor in
            setupPowerModeHotkeys()
        }
    }

    private func setupPowerModeHotkeys() {
        guard UserDefaults.standard.bool(forKey: "powerModeUIFlag") else {
            shortcutMonitor.stop()
            return
        }

        let shortcuts = PowerModeManager.shared.enabledConfigurations.reduce(into: [ShortcutAction: Shortcut]()) { result, config in
            let action = ShortcutAction.powerMode(config.id)
            if let shortcut = ShortcutStore.shortcut(for: action) {
                result[action] = shortcut
            }
        }

        shortcutMonitor.configure(
            shortcuts: shortcuts,
            onKeyDown: { _, _ in },
            onKeyUp: { [weak self] action, _ in
                Task { @MainActor in
                    guard case .powerMode(let powerModeId) = action else { return }
                    await self?.handlePowerModeHotkey(powerModeId: powerModeId)
                }
            }
        )
    }

    private func handlePowerModeHotkey(powerModeId: UUID) async {
        guard let engine = engine,
              canProcessHotkeyAction(engine: engine) else { return }

        guard let config = PowerModeManager.shared.getConfiguration(with: powerModeId),
              config.isEnabled,
              ShortcutStore.shortcut(for: .powerMode(config.id)) != nil else {
            return
        }

        await engine.recorderUIManager?.toggleMiniRecorder(powerModeId: powerModeId)
    }

    private func canProcessHotkeyAction(engine: VoiceInkEngine) -> Bool {
        engine.recordingState != .transcribing &&
        engine.recordingState != .enhancing &&
        engine.recordingState != .busy
    }
}
