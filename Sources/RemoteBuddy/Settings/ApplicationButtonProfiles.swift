import AppKit
import Foundation

/// Per-application button overrides, chosen by the frontmost application at the moment a
/// remote button is resolved. Only buttons and triggers listed in a profile change; every
/// other button keeps the remote's own mapping, so a profile lists just what differs.
///
/// Stored as JSON under `applicationButtonProfiles`:
/// `{"com.anthropic.claudefordesktop": {"name": "Claude",
///   "buttons": {"volume_up": {"singleClick": {"action": "customShortcut", "shortcut": {...}}}}}}`
struct ApplicationButtonProfile: Codable, Equatable {
    var name: String?
    /// RemoteButton raw value → ButtonTrigger raw value → action.
    var buttons: [String: [String: ConfiguredButtonAction]]
    /// The key the voice button sends to start and stop dictation in this application,
    /// for example the application's own dictation shortcut instead of Fn.
    var voiceKeyMode: VoiceKeyMode?

    init(name: String? = nil, buttons: [String: [String: ConfiguredButtonAction]] = [:],
         voiceKeyMode: VoiceKeyMode? = nil) {
        self.name = name
        self.buttons = buttons
        self.voiceKeyMode = voiceKeyMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        buttons = try container.decodeIfPresent([String: [String: ConfiguredButtonAction]].self, forKey: .buttons) ?? [:]
        voiceKeyMode = try container.decodeIfPresent(VoiceKeyMode.self, forKey: .voiceKeyMode)
    }

    func action(for button: RemoteButton, trigger: ButtonTrigger) -> ConfiguredButtonAction? {
        buttons[button.rawValue]?[trigger.rawValue]
    }

    mutating func setAction(_ action: ConfiguredButtonAction?, for button: RemoteButton, trigger: ButtonTrigger) {
        var triggers = buttons[button.rawValue] ?? [:]
        triggers[trigger.rawValue] = action
        buttons[button.rawValue] = triggers.isEmpty ? nil : triggers
    }
}

enum ApplicationButtonProfiles {
    static let defaultsKey = "applicationButtonProfiles"

    static func decode(_ data: Data?) -> [String: ApplicationButtonProfile] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: ApplicationButtonProfile].self, from: data)) ?? [:]
    }

    static func encode(_ profiles: [String: ApplicationButtonProfile]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(profiles)
    }

    @MainActor
    static func currentFrontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

extension AppSettings {
    /// Profiles keyed by bundle identifier. Decoded once per stored value, so resolving a
    /// button several times per press does not re-read JSON.
    var applicationButtonProfiles: [String: ApplicationButtonProfile] {
        get {
            let data = defaults.data(forKey: ApplicationButtonProfiles.defaultsKey)
            if data != applicationButtonProfilesCache.data {
                applicationButtonProfilesCache = (data, ApplicationButtonProfiles.decode(data))
            }
            return applicationButtonProfilesCache.profiles
        }
        set {
            let data = newValue.isEmpty ? nil : ApplicationButtonProfiles.encode(newValue)
            defaults.set(data, forKey: ApplicationButtonProfiles.defaultsKey)
            applicationButtonProfilesCache = (data, newValue)
        }
    }

    /// The key the voice button sends when a dictation starts now: the frontmost
    /// application's voice key when its profile has one, otherwise the configured one.
    /// Voice-trigger tests during onboarding always use the configured key.
    var voiceKeyModeForFrontmostApplication: VoiceKeyMode {
        guard !isTestingVoiceTrigger, let bundleID = frontmostApplicationBundleIdentifier(),
              let mode = applicationButtonProfiles[bundleID]?.voiceKeyMode else { return effectiveVoiceKeyMode }
        return mode
    }

    /// The frontmost application's override for this button and trigger, if any.
    func applicationButtonOverride(for button: RemoteButton, trigger: ButtonTrigger) -> ConfiguredButtonAction? {
        let profiles = applicationButtonProfiles
        guard !profiles.isEmpty, let bundleID = frontmostApplicationBundleIdentifier(),
              let profile = profiles[bundleID] else { return nil }
        return profile.action(for: button, trigger: trigger)
    }
}
