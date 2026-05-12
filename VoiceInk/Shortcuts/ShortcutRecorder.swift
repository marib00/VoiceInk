import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

struct ShortcutRecorder: View {
    let action: ShortcutAction
    let onShortcutChanged: () -> Void

    @StateObject private var recorder = ShortcutRecorderModel()
    @State private var shortcut: Shortcut?

    init(action: ShortcutAction, onShortcutChanged: @escaping () -> Void = {}) {
        self.action = action
        self.onShortcutChanged = onShortcutChanged
        _shortcut = State(initialValue: ShortcutStore.shortcut(for: action))
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if recorder.isRecording {
                    recorder.cancel()
                } else {
                    clearShortcutBeforeRecording()
                    recorder.start(action: action) { newShortcut in
                        shortcut = newShortcut
                        onShortcutChanged()
                    }
                }
            } label: {
                ShortcutVisualization(
                    shortcut: recorder.isRecording ? recorder.previewShortcut : shortcut,
                    isRecording: recorder.isRecording
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .help(accessibilityLabel)

            if shortcut != nil {
                Button {
                    recorder.cancel()
                    ShortcutStore.setShortcut(nil, for: action)
                    shortcut = nil
                    onShortcutChanged()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear shortcut")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { notification in
            guard let changedAction = notification.object as? ShortcutAction, changedAction == action else { return }
            shortcut = ShortcutStore.shortcut(for: action)
        }
        .onDisappear {
            recorder.cancel()
        }
    }

    private var accessibilityLabel: String {
        if recorder.isRecording {
            return recorder.previewShortcut?.displayString ?? "Press shortcut"
        }

        return shortcut?.displayString ?? "Record shortcut"
    }

    private func clearShortcutBeforeRecording() {
        ShortcutStore.setShortcut(nil, for: action)
        shortcut = nil
        onShortcutChanged()
    }
}

private struct ShortcutVisualization: View {
    let shortcut: Shortcut?
    let isRecording: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let shortcut {
                ForEach(Array(shortcut.displayTokens.enumerated()), id: \.offset) { _, token in
                    ShortcutKeyCap(title: token, isRecording: isRecording)
                }
            } else {
                if isRecording {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }

                Text(isRecording ? "Press shortcut" : "Record")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(isRecording ? .primary : .secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(minWidth: shortcut == nil ? 104 : nil, minHeight: 26)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isRecording ? Color.accentColor.opacity(0.14) : Color(NSColor.controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isRecording ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.25), lineWidth: 1)
        }
    }
}

private struct ShortcutKeyCap: View {
    let title: String
    let isRecording: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 5)
            .frame(minHeight: 18)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(borderColor, lineWidth: 1)
            }
    }

    private var foregroundColor: Color {
        Color(NSColor.textBackgroundColor)
    }

    private var backgroundColor: Color {
        Color(NSColor.labelColor)
    }

    private var borderColor: Color {
        isRecording ? Color.accentColor.opacity(0.65) : foregroundColor.opacity(0.28)
    }
}

final class ShortcutRecorderModel: ObservableObject {
    @Published var isRecording = false
    @Published var previewShortcut: Shortcut?

    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var onCapture: ((Shortcut) -> Void)?
    private var activeAction: ShortcutAction?
    private var pendingModifierShortcut: Shortcut?
    private var peakModifierFlags: NSEvent.ModifierFlags = []

    private static var hasRequestedListenEventAccess = false

    deinit {
        removeRecordingEventTap()
    }

    func start(action: ShortcutAction, onCapture: @escaping (Shortcut) -> Void) {
        cancel()

        activeAction = action
        self.onCapture = onCapture
        isRecording = true
        previewShortcut = nil

        guard installRecordingEventTap() else {
            cancel()
            showErrorNotification("Input Monitoring required to record shortcuts")
            return
        }
    }

    func cancel() {
        removeRecordingEventTap()
        resetRecordingState()
    }

    private func finish(with shortcut: Shortcut) {
        guard let activeAction else {
            cancel()
            return
        }

        if let validationError = ShortcutValidator.validationError(for: shortcut, action: activeAction) {
            cancel()
            showErrorNotification(validationError.notificationTitle(for: shortcut))
            return
        }

        let capture = onCapture
        removeRecordingEventTap()
        resetRecordingState()

        ShortcutStore.setShortcut(shortcut, for: activeAction)
        capture?(shortcut)
    }

    private func resetRecordingState() {
        isRecording = false
        previewShortcut = nil
        onCapture = nil
        activeAction = nil
        pendingModifierShortcut = nil
        peakModifierFlags = []
    }

    private func showErrorNotification(_ title: String) {
        Task { @MainActor in
            NotificationManager.shared.showNotification(
                title: title,
                type: .error
            )
        }
    }

    private func installRecordingEventTap() -> Bool {
        guard Self.hasListenEventAccess() else {
            return false
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let recorder = Unmanaged<ShortcutRecorderModel>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let eventTap = recorder.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let shouldSuppress = recorder.handleRecordingEvent(type: type, event: event)
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        // NSEvent global monitors cannot suppress system shortcuts like Command-Space,
        // so recording uses a short-lived active tap and removes it immediately after capture.
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.recordingEventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            return false
        }

        self.eventTap = eventTap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private static func hasListenEventAccess() -> Bool {
        if CGPreflightListenEventAccess() {
            return true
        }

        guard !hasRequestedListenEventAccess else {
            return false
        }

        hasRequestedListenEventAccess = true
        return CGRequestListenEventAccess()
    }

    private func removeRecordingEventTap() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func handleRecordingEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard isRecording else {
            return false
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))

        switch type {
        case .keyDown:
            return handleKeyDown(keyCode: keyCode, modifierFlags: modifierFlags)
        case .flagsChanged:
            return handleFlagsChanged(keyCode: keyCode, modifierFlags: modifierFlags)
        default:
            return false
        }
    }

    private func handleKeyDown(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let modifiers = Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: keyCode)

        if keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            cancel()
            return true
        }

        guard !Shortcut.isModifierKeyCode(keyCode) else {
            return true
        }

        let shortcut = Shortcut.key(keyCode: keyCode, modifierFlags: modifiers)
        previewShortcut = shortcut
        finish(with: shortcut)
        return true
    }

    private func handleFlagsChanged(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let modifiers = Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: keyCode)

        if modifiers.isEmpty,
           Shortcut.isFunctionKeyCode(keyCode),
           Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: nil).contains(.function) {
            return true
        }

        if !modifiers.isEmpty {
            peakModifierFlags.formUnion(modifiers)
            let singleModifierKeyCode = Shortcut.modifierKeyCodeForSingleModifierEvent(
                keyCode: keyCode,
                modifiers: peakModifierFlags
            )
            let shortcut = Shortcut.modifierOnly(
                keyCode: singleModifierKeyCode,
                modifierFlags: peakModifierFlags
            )

            pendingModifierShortcut = shortcut
            previewShortcut = shortcut
            return true
        }

        if let pendingModifierShortcut {
            finish(with: pendingModifierShortcut)
        }

        return true
    }

    private static let recordingEventMask: CGEventMask = [
        CGEventType.keyDown,
        CGEventType.flagsChanged
    ].reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << Int(type.rawValue))
    }
}
