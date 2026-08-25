// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Settings > Mouse > Mouse button shortcuts: the switch, one row per mapped
/// button with its recorded combination, and a capture flow that asks for a
/// real press instead of making the user guess button numbers.
struct MouseButtonShortcutsSection: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var service = MouseButtonShortcutService.shared
    @AppStorage(DefaultsKey.mouseButtonShortcutsEnabled) private var enabled = false

    @State private var mappings: [Int64: MouseButtonConfig] = MouseButtonShortcutSupport.decodeActions(
        UserDefaults.standard.data(forKey: DefaultsKey.mouseButtonActions)
    )
    /// A button that was just captured and is waiting for its first key
    /// combination. Nothing persists until the combination lands, so backing
    /// out leaves no half-made row behind.
    @State private var pendingButton: Int64?
    @State private var capturing = false
    @State private var captureFeedback: String?
    @State private var recordingButton: Int64?
    /// The recorder's complaint and the row it belongs to; it stays visible
    /// until that row records again, the same way the shortcut rows behave.
    @State private var recordError: String?
    @State private var recordErrorButton: Int64?

    private var text: MouseButtonFeatureStrings { FeatureStrings.mouseButtons(l10n.language) }

    var body: some View {
        Section(text.pageTitle) {
            Toggle(text.enableLabel, isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    if !on { stopCapture() }
                    MouseButtonShortcutService.shared.syncWithPreferences()
                    if on, !permissions.accessibility {
                        permissions.requestAccessibility()
                    }
                }
            Text(text.enableCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if enabled {
                if mappings.isEmpty, pendingButton == nil {
                    Text(text.emptyCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(MouseButtonShortcutSupport.sortedButtons(mappings), id: \.self) { button in
                    mappingRow(button, config: mappings[button])
                }
                if let pendingButton {
                    mappingRow(pendingButton, config: nil)
                }
                captureRow
                MouseExceptionsList(scope: .buttonShortcuts)
            }
        }
        .settingsSectionAnchor(.mouseButtonShortcuts)
        .onDisappear {
            stopCapture()
        }
    }

    // MARK: - Rows

    private func mappingRow(_ button: Int64, config: MouseButtonConfig?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(MouseButtonShortcutSupport.buttonName(for: button, strings: text))
                    .bold()
                Spacer()
                Button {
                    remove(button)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(text.removeButton)
                .accessibilityLabel(text.removeButton)
            }

            // Sub-actions
            let currentConfig = config ?? MouseButtonConfig()

            actionPickerRow(button: button, label: "Click", actionPath: \.click, currentConfig: currentConfig)
            actionPickerRow(button: button, label: "Hold", actionPath: \.hold, currentConfig: currentConfig)
            actionPickerRow(button: button, label: "Drag", actionPath: \.drag, currentConfig: currentConfig)
            actionPickerRow(button: button, label: "Scroll", actionPath: \.scroll, currentConfig: currentConfig)
        }
        .padding(.vertical, 4)
    }

    private func actionPickerRow(button: Int64, label: String, actionPath: WritableKeyPath<MouseButtonConfig, MouseButtonAction?>, currentConfig: MouseButtonConfig) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .frame(width: 50, alignment: .leading)

            let action = currentConfig[keyPath: actionPath]

            Picker("", selection: Binding<String>(
                get: { action?.type.rawValue ?? "none" },
                set: { newValue in
                    var newConfig = currentConfig
                    if newValue == "none" {
                        newConfig[keyPath: actionPath] = nil
                    } else if let type = MouseButtonActionType(rawValue: newValue) {
                        newConfig[keyPath: actionPath] = MouseButtonAction(type: type)
                    }
                    saveConfig(button: button, config: newConfig)
                }
            )) {
                Text("None").tag("none")
                Text("Shortcut").tag(MouseButtonActionType.shortcut.rawValue)
                Text("Spaces & Mission Control").tag(MouseButtonActionType.missionControlAndSpaces.rawValue)
            }
            .labelsHidden()
            .frame(width: 180)

            if action?.type == .shortcut {
                ShortcutRecorderButton(shortcut: action?.shortcut ?? GlobalShortcut.keepAwakeDefault,
                                       isEnabled: true,
                                       waitingTitle: l10n.s.shortcutPressKeys,
                                       emptyTitle: action?.shortcut == nil ? text.setShortcutButton : nil,
                                       notCapturedAction: { setRecordError(l10n.s.shortcutNotCaptured, button) },
                                       recordingChanged: { recording in
                                           recordingButton = recording ? button : nil
                                           if recording { setRecordError(nil, button) }
                                       },
                                       invalidAction: { setRecordError(l10n.s.shortcutInvalid, button) },
                                       captureAction: { shortcut in
                                            var newConfig = currentConfig
                                            newConfig[keyPath: actionPath] = MouseButtonAction(type: .shortcut, shortcut: shortcut)
                                            saveConfig(button: button, config: newConfig)
                                       })
                    .frame(width: 108)
            }
        }
    }

    @ViewBuilder
    private var captureRow: some View {
        if capturing {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if service.isRunning {
                        Image(systemName: "circle.dashed")
                            .foregroundStyle(.secondary)
                        Text(text.captureWaiting)
                    } else {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        Text(text.captureBlind)
                    }
                    Spacer()
                    Button(text.captureCancel) { stopCapture() }
                }
                if let captureFeedback {
                    Text(captureFeedback)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(text.captureHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onReceive(service.$lastInputSeen) { seen in
                handleCapture(seen)
            }
        } else {
            Button {
                startCapture()
            } label: {
                Label(text.addButton, systemImage: "plus")
            }
        }
    }

    // MARK: - Capture

    private func startCapture() {
        captureFeedback = nil
        capturing = true
        MouseButtonShortcutService.shared.setCapturing(true)
        if !permissions.accessibility {
            permissions.requestAccessibility()
        }
    }

    private func stopCapture() {
        guard capturing else { return }
        capturing = false
        captureFeedback = nil
        MouseButtonShortcutService.shared.setCapturing(false)
    }

    private func handleCapture(_ seen: Int64?) {
        guard capturing, let seen else { return }
        if !MouseButtonShortcutSupport.canMap(seen) {
            captureFeedback = text.captureUnsupported
        } else if RadialMenuSupport.claimsMouseButton(seen) {
            captureFeedback = text.captureWheel
        } else if mappings[seen] != nil || pendingButton == seen {
            captureFeedback = text.captureExists
        } else {
            pendingButton = seen
            recordError = nil
            stopCapture()
        }
    }

    // MARK: - Persistence

    private func setRecordError(_ message: String?, _ button: Int64) {
        recordError = message
        recordErrorButton = message == nil ? nil : button
    }

    private func saveConfig(button: Int64, config: MouseButtonConfig) {
        mappings[button] = config
        if pendingButton == button { pendingButton = nil }
        setRecordError(nil, button)
        persist()
    }


    private func remove(_ button: Int64) {
        if recordErrorButton == button { setRecordError(nil, button) }
        if pendingButton == button {
            pendingButton = nil
            return
        }
        mappings.removeValue(forKey: button)
        persist()
    }

    private func persist() {
        if let data = MouseButtonShortcutSupport.encodeActions(mappings) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.mouseButtonActions)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.mouseButtonActions)
        }
        MouseButtonShortcutService.shared.syncWithPreferences()
    }
}
