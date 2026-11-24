import CoreAudio
import Foundation

/// A microphone the Mac itself offers (built-in, USB, AirPods), as opposed to a remote's.
struct SystemMicrophone: Identifiable, Equatable {
    /// Core Audio device UID, which is also the AVCaptureDevice unique ID.
    let id: String
    let deviceID: AudioDeviceID
    let name: String
    var isDefault: Bool
    /// Input volume from 0 to 1, or nil when the device has no software input volume.
    var volume: Float?
    var isVolumeSettable: Bool
    /// A software device installed by another app (Teams, Zoom, BlackHole), not a real microphone.
    var isVirtual: Bool = false
}

enum SystemMicrophoneCatalog {
    static func microphones() -> [SystemMicrophone] {
        let defaultID = defaultInputDeviceID()
        return CoreAudioDeviceCatalog.inputDevices()
            .filter(shouldList)
            .map { device in
                let volume = inputVolume(of: device.id)
                return SystemMicrophone(
                    id: device.uid, deviceID: device.id, name: device.name,
                    isDefault: device.id == defaultID,
                    volume: volume.value, isVolumeSettable: volume.settable,
                    isVirtual: isVirtual(device.id))
            }
            .sorted { lhs, rhs in
                if lhs.isVirtual != rhs.isVirtual { return !lhs.isVirtual }
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Remote Buddy's own virtual microphone carries the remote's audio, which already has
    /// its own meter above, so listing it again would only confuse.
    static func shouldList(_ device: AudioDeviceInfo) -> Bool {
        device.uid != BuddyMicrophoneDevicePolicy.deviceUID &&
            CoreAudioDeviceCatalog.shouldPresentToUser(device)
    }

    static func isVirtual(_ deviceID: AudioDeviceID) -> Bool {
        var address = systemAddress(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = systemAddress(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Volume elements to use: the main element when the device has one, otherwise each
    /// input channel (some USB and Bluetooth microphones only expose per-channel volume).
    private static func volumeElements(of deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var main = volumeAddress(kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(deviceID, &main) { return [kAudioObjectPropertyElementMain] }
        let channels = CoreAudioDeviceCatalog.inputChannelCount(for: deviceID)
        guard channels > 0 else { return [] }
        return (1...channels).map { AudioObjectPropertyElement($0) }.filter { element in
            var address = volumeAddress(element)
            return AudioObjectHasProperty(deviceID, &address)
        }
    }

    static func inputVolume(of deviceID: AudioDeviceID) -> (value: Float?, settable: Bool) {
        let elements = volumeElements(of: deviceID)
        var values: [Float] = []
        var settable = false
        for element in elements {
            var address = volumeAddress(element)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
                values.append(value)
            }
            var isSettable = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr, isSettable.boolValue {
                settable = true
            }
        }
        guard !values.isEmpty else { return (nil, false) }
        return (values.reduce(0, +) / Float(values.count), settable)
    }

    @discardableResult
    static func setInputVolume(_ volume: Float, of deviceID: AudioDeviceID) -> Bool {
        let clamped = min(1, max(0, volume))
        var wrote = false
        for element in volumeElements(of: deviceID) {
            var address = volumeAddress(element)
            var isSettable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
                  isSettable.boolValue else { continue }
            if CoreAudioDevicePropertyWriter.write(Float32(clamped), to: deviceID, address: &address) {
                wrote = true
            }
        }
        return wrote
    }

    private static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeInput, mElement: element)
    }
}
