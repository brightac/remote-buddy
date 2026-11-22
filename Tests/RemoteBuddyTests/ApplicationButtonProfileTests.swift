import AppKit
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Application button profiles") @MainActor
struct ApplicationButtonProfileTests {
    private let claude = "com.anthropic.claudefordesktop"
    private let codex = "com.openai.codex"
    private let nextSession = CustomKeyboardShortcut(keyCode: 125, modifierFlags: .option, keyLabel: "↓")
    private let nextChat = CustomKeyboardShortcut(keyCode: 30, modifierFlags: [.command, .option], keyLabel: "]")

    private func withSettings(_ body: (AppSettings) throws -> Void) throws {
        let name = "app-profiles-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(AppSettings(defaults: defaults))
    }

    private func profiles() -> [String: ApplicationButtonProfile] {
        var claudeProfile = ApplicationButtonProfile(name: "Claude")
        claudeProfile.setAction(ConfiguredButtonAction(action: .customShortcut, shortcut: nextSession),
                                for: .volumeDown, trigger: .singleClick)
        claudeProfile.setAction(ConfiguredButtonAction(action: .commandUndo, shortcut: nil),
                                for: .input, trigger: .longPress)
        var codexProfile = ApplicationButtonProfile(name: "Codex")
        codexProfile.setAction(ConfiguredButtonAction(action: .customShortcut, shortcut: nextChat),
                               for: .volumeDown, trigger: .singleClick)
        return [claude: claudeProfile, codex: codexProfile]
    }

    @Test func frontmostApplicationChoosesTheProfile() throws {
        try withSettings { settings in
            settings.applicationButtonProfiles = profiles()
            var front: String? = claude
            settings.frontmostApplicationBundleIdentifier = { front }
            let id = settings.selectedRemoteProfileID

            #expect(settings.configuredAction(for: .volumeDown, trigger: .singleClick, profileID: id).shortcut == nextSession)
            #expect(settings.configuredAction(for: .input, trigger: .longPress, profileID: id).action == .commandUndo)

            front = codex
            #expect(settings.configuredAction(for: .volumeDown, trigger: .singleClick, profileID: id).shortcut == nextChat)
            // Not listed in the Codex profile: falls back to the remote's mapping.
            #expect(settings.configuredAction(for: .input, trigger: .longPress, profileID: id)
                == settings.configuredAction(for: .input, trigger: .longPress))

            front = "com.apple.Notes"
            #expect(settings.configuredAction(for: .volumeDown, trigger: .singleClick, profileID: id).action == .volumeDown)
        }
    }

    @Test func mappingPageKeepsShowingTheRemoteMapping() throws {
        try withSettings { settings in
            settings.applicationButtonProfiles = profiles()
            settings.frontmostApplicationBundleIdentifier = { "com.anthropic.claudefordesktop" }
            #expect(settings.configuredAction(for: .volumeDown, trigger: .singleClick).action == .volumeDown)
            #expect(settings.configuredBaseAction(for: .volumeDown, trigger: .singleClick).action == .volumeDown)
        }
    }

    @Test func profilesRoundTripThroughDefaults() throws {
        try withSettings { settings in
            settings.applicationButtonProfiles = profiles()
            let reloaded = AppSettings(defaults: settings.defaults)
            #expect(reloaded.applicationButtonProfiles == profiles())
            settings.applicationButtonProfiles = [:]
            #expect(settings.defaults.data(forKey: ApplicationButtonProfiles.defaultsKey) == nil)
        }
    }

    @Test func pressPerformsTheFrontmostApplicationsShortcut() throws {
        try withSettings { settings in
            settings.customMappingEnabled = true
            settings.applicationButtonProfiles = profiles()
            var front: String? = claude
            settings.frontmostApplicationBundleIdentifier = { front }
            var performed: [ConfiguredButtonAction] = []
            let clock = ControlledTestScheduler()
            let profile = UUID()
            let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
                scheduler: clock, runtimePermissions: { true }, nativeSuppressionAvailable: { true },
                actionPerformer: { _, _, configured in performed.append(configured); return true },
                frontmostBundleIdentifier: { front }, diagnosticLogger: { _ in })
            monitor.connectSimulatedDevice(fingerprint: "app-profile", profileID: profile, isSeized: true)
            defer { monitor.disconnectSimulatedDevice() }
            let usage = RemoteButton.volumeDown.hidUsage
            let tap: @MainActor (UInt64) -> Void = { ms in
                clock.advance(to: ms)
                monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
                clock.advance(to: ms + 50)
                monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
                clock.advance(to: ms + 600)
            }
            tap(0)
            front = codex
            tap(1_000)
            front = nil
            tap(2_000)
            #expect(performed.map(\.shortcut) == [nextSession, nextChat, nil])
            #expect(performed.last?.action == .volumeDown)
        }
    }

    @Test func voiceKeyFollowsTheFrontmostApplicationForWholeDictations() throws {
        try withSettings { settings in
            let claudeDictation = VoiceKeyMode.shortcut(
                CustomKeyboardShortcut(keyCode: 2, modifierFlags: .command, keyLabel: "D"))
            var all = profiles()
            all[claude]?.voiceKeyMode = claudeDictation
            settings.applicationButtonProfiles = all
            var front: String? = claude
            settings.frontmostApplicationBundleIdentifier = { front }
            #expect(settings.voiceKeyModeForFrontmostApplication == claudeDictation)
            front = codex  // Codex profile has no voice key: the configured one applies.
            #expect(settings.voiceKeyModeForFrontmostApplication == settings.effectiveVoiceKeyMode)

            var sent: [(VoiceKeyMode, Bool)] = []
            let trigger = VoiceTapTrigger(selectedMode: { settings.voiceKeyModeForFrontmostApplication },
                                          setKey: { sent.append(($0, $1)); return true })
            front = claude
            _ = trigger.setPressed(true); _ = trigger.setPressed(false)
            front = codex  // Switching apps mid-dictation must not change the stop key.
            _ = trigger.setPressed(true); _ = trigger.setPressed(false)
            #expect(sent.map(\.0) == Array(repeating: claudeDictation, count: 4))
            trigger.reset()
            _ = trigger.setPressed(true)
            #expect(sent.last?.0 == settings.effectiveVoiceKeyMode)
        }
    }

    @Test func profileWithoutVoiceKeyDecodesFromOlderJSON() throws {
        let json = #"{"com.openai.codex":{"name":"Codex","buttons":{}}}"#
        let decoded = ApplicationButtonProfiles.decode(Data(json.utf8))
        #expect(decoded["com.openai.codex"]?.voiceKeyMode == nil)
        #expect(decoded["com.openai.codex"]?.name == "Codex")
    }
}
