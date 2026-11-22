import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Chooses whose buttons the mapping page edits: the remote's own mapping, used in every
/// application, or one application's overrides, used while that application is frontmost.
extension SettingsView {
    /// Voice keys offered for an application, besides following the remote's own setting.
    static let applicationVoiceKeyChoices: [VoiceKeyMode] = [
        .function, .rightOption, .rightCommand,
        .shortcut(CustomKeyboardShortcut(keyCode: 2, modifierFlags: [.command], keyLabel: "D")),
        .shortcut(CustomKeyboardShortcut(keyCode: 2, modifierFlags: [.command, .shift], keyLabel: "D")),
    ]

    var mappingApplicationScopeBar: some View {
        let profiles = settings.sortedApplicationButtonProfiles
        let bundleID = editingApplicationBundleID
        return GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Text(localization.text("button_mapping.app_scope.title"))
                        .font(.system(size: 13, weight: .semibold))
                    Picker("", selection: Binding<String?>(
                        get: { editingApplicationBundleID },
                        set: { selectMappingApplication($0) }
                    )) {
                        Text(localization.text("button_mapping.app_scope.all_apps")).tag(Optional<String>.none)
                        if !profiles.isEmpty { Divider() }
                        ForEach(profiles, id: \.bundleID) { entry in
                            Text(ApplicationButtonProfiles.displayName(bundleID: entry.bundleID, profile: entry.profile))
                                .tag(Optional(entry.bundleID))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("mapping.app-scope.picker")

                    Button {
                        chooseApplicationForMapping()
                    } label: {
                        Label(localization.text("button_mapping.app_scope.add"), systemImage: "plus")
                    }
                    .compatibilityButtonStyle(.standard)

                    Spacer(minLength: 8)

                    if let bundleID {
                        Button(role: .destructive) {
                            settings.removeApplicationButtonProfile(bundleID: bundleID)
                            selectMappingApplication(nil)
                        } label: {
                            Label(localization.text("button_mapping.app_scope.remove"), systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .compatibilityButtonStyle(.standard)
                    }
                }

                if let bundleID {
                    HStack(alignment: .center, spacing: 12) {
                        Text(localization.text("button_mapping.app_scope.voice_key"))
                            .font(.system(size: 13))
                        Picker("", selection: Binding<String>(
                            get: { settings.applicationButtonProfiles[bundleID]?.voiceKeyMode?.rawValue ?? "" },
                            set: { settings.setApplicationVoiceKeyMode(VoiceKeyMode(rawValue: $0), bundleID: bundleID) }
                        )) {
                            Text(localization.text("button_mapping.app_scope.voice_key.follow")).tag("")
                            ForEach(applicationVoiceKeyChoices(for: bundleID), id: \.rawValue) { mode in
                                Text(mode.displayName(using: localization)).tag(mode.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                    }
                    Text(LocalizedMessage(
                        "button_mapping.app_scope.editing_hint",
                        arguments: [ApplicationButtonProfiles.displayName(
                            bundleID: bundleID, profile: settings.applicationButtonProfiles[bundleID])]
                    ).text(using: localization))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(localization.text("button_mapping.app_scope.all_apps_hint"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func applicationVoiceKeyChoices(for bundleID: String) -> [VoiceKeyMode] {
        var choices = Self.applicationVoiceKeyChoices
        if let current = settings.applicationButtonProfiles[bundleID]?.voiceKeyMode,
           !choices.contains(where: { $0.rawValue == current.rawValue }) {
            choices.append(current)
        }
        return choices
    }

    func selectMappingApplication(_ bundleID: String?) {
        mappingApplicationBundleID = bundleID
        mappingEditingTarget = nil
        shortcutCaptureTarget = nil
        applicationShortcutCaptureProfileID = nil
        shortcutCaptureFeedback = nil
        mappingActionFilter = .basicKeys
    }

    private func chooseApplicationForMapping() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = localization.text("button_mapping.app_scope.add")
        guard panel.runModal() == .OK, let url = panel.url,
              let identity = ApplicationButtonProfiles.applicationIdentity(at: url) else { return }
        settings.addApplicationButtonProfile(bundleID: identity.bundleID, name: identity.name)
        selectMappingApplication(identity.bundleID)
    }
}
