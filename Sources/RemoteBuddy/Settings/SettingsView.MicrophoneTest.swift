import SwiftUI

extension SettingsView {
    /// Every remote's microphone on the first page: a level meter, the loudness (gain)
    /// slider and a test switch, so all of them can be checked and tuned in one place.
    @ViewBuilder
    var generalMicrophoneTestSection: some View {
        let profiles = RemoteDeviceNamePolicy.sortedForCards(
            settings.remoteDeviceProfiles,
            modelName: remoteModelName,
            systemName: { model.systemDeviceName(for: $0) }
        ).filter { $0.bluetoothIdentifier != nil }
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(localization.text("audio.mic_test.section_title"))
                    .font(.title3.weight(.semibold))
                ForEach(profiles) { profile in
                    if let identifier = profile.bluetoothIdentifier {
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(model.isRemoteConnected(profile.id) ? Color.green : Color.secondary.opacity(0.4))
                                        .frame(width: 8, height: 8)
                                    Text(remoteModelName(profile)).font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                }
                                HStack(spacing: 12) {
                                    Text(localization.text("audio.gain.title")).font(.system(size: 13))
                                    Slider(value: Binding(get: { settings.gainDB(for: profile.id) },
                                                          set: { settings.setGainDB($0, for: profile.id) }),
                                           in: 0...24, step: 1)
                                    Text("\(Int(settings.gainDB(for: profile.id))) dB")
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 54, alignment: .trailing)
                                }
                                MicrophoneTestPanel(monitor: model.microphoneLevels, identifier: identifier,
                                                    isConnected: model.isRemoteConnected(profile.id))
                            }
                        }
                    }
                }
            }
            .onDisappear { model.microphoneLevels.stopTest(reason: "page_closed") }
        }
    }
}
