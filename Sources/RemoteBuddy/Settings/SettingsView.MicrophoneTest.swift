import SwiftUI

extension SettingsView {
    /// Every microphone on the first page: each remote's with its loudness (gain) slider,
    /// then the Mac's own with their input volume, each with a level meter and a test switch.
    var generalMicrophoneTestSection: some View {
        let profiles = RemoteDeviceNamePolicy.sortedForCards(
            settings.remoteDeviceProfiles,
            modelName: remoteModelName,
            systemName: { model.systemDeviceName(for: $0) }
        ).filter { $0.bluetoothIdentifier != nil }
        return VStack(alignment: .leading, spacing: 12) {
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
                                Image(systemName: "av.remote").foregroundStyle(.secondary)
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
                                                isConnected: model.isRemoteConnected(profile.id),
                                                onStart: { model.systemMicrophones.stopTest(reason: "switch") })
                        }
                    }
                }
            }
            SystemMicrophoneList(monitor: model.systemMicrophones,
                                 onStart: { model.microphoneLevels.stopTest(reason: "switch") })
        }
        .onDisappear { model.microphoneLevels.stopTest(reason: "page_closed") }
    }
}

/// The Mac's own microphones (built-in, USB, AirPods), each with its system input volume.
struct SystemMicrophoneList: View {
    @ObservedObject var monitor: SystemMicrophoneMonitor
    @EnvironmentObject private var localization: LocalizationStore
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if monitor.permissionDenied {
                Text(localization.text("audio.system_mic.permission_denied"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if monitor.microphones.isEmpty {
                Text(localization.text("audio.system_mic.none"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(monitor.microphones) { microphone in
                GlassPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "mic").foregroundStyle(.secondary)
                            Text(microphone.name).font(.system(size: 14, weight: .semibold))
                            if microphone.isVirtual {
                                Text(localization.text("audio.system_mic.virtual"))
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                    .help(localization.text("audio.system_mic.virtual_help"))
                            }
                            if microphone.isDefault {
                                Text(localization.text("audio.system_mic.default"))
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            }
                            Spacer()
                        }
                        HStack(spacing: 12) {
                            Text(localization.text("audio.system_mic.volume")).font(.system(size: 13))
                            if let volume = microphone.volume, microphone.isVolumeSettable {
                                Slider(value: Binding(get: { Double(volume) },
                                                      set: { monitor.setVolume(Float($0), for: microphone) }),
                                       in: 0...1)
                                Text("\(Int((volume * 100).rounded()))%")
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 54, alignment: .trailing)
                            } else {
                                Text(localization.text("audio.system_mic.volume_fixed"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        let isTesting = monitor.testingID == microphone.id
                        MicrophoneMeterPanel(
                            reading: monitor.readings[microphone.id],
                            isTesting: isTesting,
                            canStart: true,
                            hintKey: "audio.system_mic.hint",
                            testingHintKey: "audio.system_mic.testing_hint",
                            onToggle: {
                                if isTesting {
                                    monitor.stopTest()
                                } else {
                                    onStart()
                                    monitor.startTest(for: microphone.id)
                                }
                            },
                            onResetClipping: { monitor.resetClipping(for: microphone.id) }
                        )
                    }
                }
            }
        }
        .onAppear { monitor.startWatchingDevices() }
        .onDisappear { monitor.stopWatchingDevices() }
    }
}
