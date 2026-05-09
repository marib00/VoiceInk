import Foundation
import KeyboardShortcuts
import AppKit

extension KeyboardShortcuts.Name {
    static let escapeRecorder = Self("escapeRecorder")
    static let cancelRecorder = Self("cancelRecorder")
    static let toggleEnhancement = Self("toggleEnhancement", default: .init(.e, modifiers: .command))
    // AI Prompt selection shortcuts
    static let selectPrompt1 = Self("selectPrompt1")
    static let selectPrompt2 = Self("selectPrompt2")
    static let selectPrompt3 = Self("selectPrompt3")
    static let selectPrompt4 = Self("selectPrompt4")
    static let selectPrompt5 = Self("selectPrompt5")
    static let selectPrompt6 = Self("selectPrompt6")
    static let selectPrompt7 = Self("selectPrompt7")
    static let selectPrompt8 = Self("selectPrompt8")
    static let selectPrompt9 = Self("selectPrompt9")
    static let selectPrompt10 = Self("selectPrompt10")
    // Power Mode selection shortcuts
    static let selectPowerMode1 = Self("selectPowerMode1")
    static let selectPowerMode2 = Self("selectPowerMode2")
    static let selectPowerMode3 = Self("selectPowerMode3")
    static let selectPowerMode4 = Self("selectPowerMode4")
    static let selectPowerMode5 = Self("selectPowerMode5")
    static let selectPowerMode6 = Self("selectPowerMode6")
    static let selectPowerMode7 = Self("selectPowerMode7")
    static let selectPowerMode8 = Self("selectPowerMode8")
    static let selectPowerMode9 = Self("selectPowerMode9")
    static let selectPowerMode10 = Self("selectPowerMode10")
}

@MainActor
class MiniRecorderShortcutManager: ObservableObject {
    private typealias ShortcutBinding = (name: KeyboardShortcuts.Name, shortcut: KeyboardShortcuts.Shortcut)

    private var engine: VoiceInkEngine
    private var recorderUIManager: RecorderUIManager
    private var visibilityTask: Task<Void, Never>?
    
    private var isCancelHandlerSetup = false
    private var arePromptHandlersSetup = false
    private var arePowerModeHandlersSetup = false
    
    // Double-tap Escape handling
    private var escFirstPressTime: Date? = nil
    private let escSecondPressThreshold: TimeInterval = 1.5
    private var isEscapeHandlerSetup = false
    private var escapeTimeoutTask: Task<Void, Never>?

    private let promptShortcutBindings: [ShortcutBinding] = [
        (.selectPrompt1, .init(.one, modifiers: .command)),
        (.selectPrompt2, .init(.two, modifiers: .command)),
        (.selectPrompt3, .init(.three, modifiers: .command)),
        (.selectPrompt4, .init(.four, modifiers: .command)),
        (.selectPrompt5, .init(.five, modifiers: .command)),
        (.selectPrompt6, .init(.six, modifiers: .command)),
        (.selectPrompt7, .init(.seven, modifiers: .command)),
        (.selectPrompt8, .init(.eight, modifiers: .command)),
        (.selectPrompt9, .init(.nine, modifiers: .command)),
        (.selectPrompt10, .init(.zero, modifiers: .command))
    ]

    private let powerModeShortcutBindings: [ShortcutBinding] = [
        (.selectPowerMode1, .init(.one, modifiers: .option)),
        (.selectPowerMode2, .init(.two, modifiers: .option)),
        (.selectPowerMode3, .init(.three, modifiers: .option)),
        (.selectPowerMode4, .init(.four, modifiers: .option)),
        (.selectPowerMode5, .init(.five, modifiers: .option)),
        (.selectPowerMode6, .init(.six, modifiers: .option)),
        (.selectPowerMode7, .init(.seven, modifiers: .option)),
        (.selectPowerMode8, .init(.eight, modifiers: .option)),
        (.selectPowerMode9, .init(.nine, modifiers: .option)),
        (.selectPowerMode10, .init(.zero, modifiers: .option))
    ]
    
    init(engine: VoiceInkEngine, recorderUIManager: RecorderUIManager) {
        self.engine = engine
        self.recorderUIManager = recorderUIManager
        setupEnhancementShortcut()
        setupEscapeHandlerOnce()
        setupCancelHandlerOnce()
        setupPromptHandlersOnce()
        setupPowerModeHandlersOnce()
        setupVisibilityObserver()
    }

    private func setupVisibilityObserver() {
        visibilityTask = Task { @MainActor in
            for await isVisible in recorderUIManager.$isMiniRecorderVisible.values {
                if isVisible {
                    KeyboardShortcuts.enable(.toggleEnhancement)
                    activateEscapeShortcut()
                    activateCancelShortcut()
                    setupPromptShortcuts()
                    refreshPowerModeShortcuts()
                } else {
                    KeyboardShortcuts.disable(.toggleEnhancement)
                    deactivateEscapeShortcut()
                    deactivateCancelShortcut()
                    removePromptShortcuts()
                    removePowerModeShortcuts()
                }
            }
        }
    }

    private var canUsePowerModeShortcuts: Bool {
        UserDefaults.standard.bool(forKey: "powerModeUIFlag") &&
            !PowerModeManager.shared.enabledConfigurations.isEmpty
    }

    private func refreshPowerModeShortcuts() {
        canUsePowerModeShortcuts ? setupPowerModeShortcuts() : removePowerModeShortcuts()
    }
    
    // Setup escape handler once
    private func setupEscapeHandlerOnce() {
        guard !isEscapeHandlerSetup else { return }
        isEscapeHandlerSetup = true
        
        KeyboardShortcuts.onKeyDown(for: .escapeRecorder) { [weak self] in
            Task { @MainActor in
                guard let self = self,
                      await self.recorderUIManager.isMiniRecorderVisible else { return }

                // Don't process if custom shortcut is configured
                guard KeyboardShortcuts.getShortcut(for: .cancelRecorder) == nil else { return }

                let now = Date()
                if let firstTime = self.escFirstPressTime,
                   now.timeIntervalSince(firstTime) <= self.escSecondPressThreshold {
                    self.escFirstPressTime = nil
                    await self.recorderUIManager.cancelRecording()
                } else {
                    self.escFirstPressTime = now
                    SoundManager.shared.playEscSound()
                    NotificationManager.shared.showNotification(
                        title: "Press ESC again to cancel recording",
                        type: .info,
                        duration: self.escSecondPressThreshold
                    )
                    self.escapeTimeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64((self?.escSecondPressThreshold ?? 1.5) * 1_000_000_000))
                        await MainActor.run {
                            self?.escFirstPressTime = nil
                        }
                    }
                }
            }
        }
    }
    
    private func activateEscapeShortcut() {
        // Don't activate if custom shortcut is configured
        guard KeyboardShortcuts.getShortcut(for: .cancelRecorder) == nil else { return }
        KeyboardShortcuts.setShortcut(.init(.escape), for: .escapeRecorder)
    }
    
    // Setup cancel handler once
    private func setupCancelHandlerOnce() {
        guard !isCancelHandlerSetup else { return }
        isCancelHandlerSetup = true
        
        KeyboardShortcuts.onKeyDown(for: .cancelRecorder) { [weak self] in
            Task { @MainActor in
                guard let self = self,
                      await self.recorderUIManager.isMiniRecorderVisible,
                      KeyboardShortcuts.getShortcut(for: .cancelRecorder) != nil else { return }

                await self.recorderUIManager.cancelRecording()
            }
        }
    }
    
    private func activateCancelShortcut() {
        // Handler checks if shortcut exists
    }
    
    private func deactivateEscapeShortcut() {
        KeyboardShortcuts.setShortcut(nil, for: .escapeRecorder)
        escFirstPressTime = nil
        escapeTimeoutTask?.cancel()
        escapeTimeoutTask = nil
    }
    
    private func deactivateCancelShortcut() {
        // Shortcut managed by user settings
    }
    
    private func setupEnhancementShortcut() {
        KeyboardShortcuts.onKeyDown(for: .toggleEnhancement) { [weak self] in
            Task { @MainActor in
                guard let self = self,
                      await self.recorderUIManager.isMiniRecorderVisible,
                      let enhancementService = await self.engine.getEnhancementService() else { return }
                enhancementService.isEnhancementEnabled.toggle()
            }
        }

        // Don't capture the key globally until the mini recorder is visible.
        KeyboardShortcuts.disable(.toggleEnhancement)
    }
    
    private func setupPowerModeShortcuts() {
        guard canUsePowerModeShortcuts else {
            removePowerModeShortcuts()
            return
        }

        setShortcuts(powerModeShortcutBindings)
    }

    private func setupPowerModeHandlersOnce() {
        guard !arePowerModeHandlersSetup else { return }
        arePowerModeHandlersSetup = true

        for (index, binding) in powerModeShortcutBindings.enumerated() {
            setupPowerModeHandler(for: binding.name, index: index)
        }
    }
    
    private func setupPowerModeHandler(for shortcutName: KeyboardShortcuts.Name, index: Int) {
        KeyboardShortcuts.onKeyDown(for: shortcutName) { [weak self] in
            Task { @MainActor in
                guard let self = self,
                      await self.recorderUIManager.isMiniRecorderVisible,
                      self.canUsePowerModeShortcuts else { return }

                let powerModeManager = PowerModeManager.shared
                let availableConfigurations = powerModeManager.enabledConfigurations

                guard index < availableConfigurations.count else { return }

                let selectedConfig = availableConfigurations[index]
                powerModeManager.setActiveConfiguration(selectedConfig)
                await PowerModeSessionManager.shared.beginSession(with: selectedConfig)
            }
        }
    }
    
    private func removePowerModeShortcuts() {
        removeShortcuts(powerModeShortcutBindings.map { $0.name })
    }
    
    private func setupPromptShortcuts() {
        setShortcuts(promptShortcutBindings)
    }

    private func setupPromptHandlersOnce() {
        guard !arePromptHandlersSetup else { return }
        arePromptHandlersSetup = true

        for (index, binding) in promptShortcutBindings.enumerated() {
            setupPromptHandler(for: binding.name, index: index)
        }
    }
    
    private func setupPromptHandler(for shortcutName: KeyboardShortcuts.Name, index: Int) {
        KeyboardShortcuts.onKeyDown(for: shortcutName) { [weak self] in
            Task { @MainActor in
                guard let self = self,
                      await self.recorderUIManager.isMiniRecorderVisible else { return }

                guard let enhancementService = await self.engine.getEnhancementService() else { return }
                
                let availablePrompts = enhancementService.allPrompts
                if index < availablePrompts.count {
                    if !enhancementService.isEnhancementEnabled {
                        enhancementService.isEnhancementEnabled = true
                    }
                    
                    enhancementService.setActivePrompt(availablePrompts[index])
                }
            }
        }
    }
    
    private func removePromptShortcuts() {
        removeShortcuts(promptShortcutBindings.map { $0.name })
    }

    private func setShortcuts(_ bindings: [ShortcutBinding]) {
        for binding in bindings {
            KeyboardShortcuts.setShortcut(binding.shortcut, for: binding.name)
        }
    }

    private func removeShortcuts(_ names: [KeyboardShortcuts.Name]) {
        for name in names {
            KeyboardShortcuts.setShortcut(nil, for: name)
        }
    }
    
    deinit {
        visibilityTask?.cancel()
        Task { @MainActor in
            KeyboardShortcuts.disable(.toggleEnhancement)
            deactivateEscapeShortcut()
            deactivateCancelShortcut()
            removePromptShortcuts()
            removePowerModeShortcuts()
        }
    }
}
