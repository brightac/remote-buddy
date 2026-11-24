import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Lists the Mac's own microphones and measures one of them at a time for the settings page.
/// Capture runs only while a test is on, so the menu bar app never holds a microphone open.
@MainActor
final class SystemMicrophoneMonitor: ObservableObject {
    @Published private(set) var microphones: [SystemMicrophone] = []
    @Published private(set) var readings: [String: MicrophoneLevelReading] = [:]
    @Published private(set) var testingID: String?
    @Published private(set) var permissionDenied = false

    static let testTimeout: TimeInterval = 120
    private static let publishInterval: TimeInterval = 1.0 / 20

    private var meter = MicrophoneLevelMeter()
    private var lastPublishedAt: TimeInterval = 0
    private var session: AVCaptureSession?
    private var sampleReceiver: SampleReceiver?
    private var timeoutWork: DispatchWorkItem?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private let captureQueue = DispatchQueue(label: "com.zfdang.remote-buddy.system-mic-test")

    func refresh() {
        microphones = SystemMicrophoneCatalog.microphones()
        if let testingID, !microphones.contains(where: { $0.id == testingID }) {
            stopTest(reason: "device_removed")
        }
    }

    /// Keeps the list current while the page is open, so plugging in a headset shows up.
    func startWatchingDevices() {
        refresh()
        guard deviceListListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        deviceListListener = listener
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    func stopWatchingDevices() {
        stopTest(reason: "page_closed")
        guard let listener = deviceListListener else { return }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        deviceListListener = nil
    }

    func setVolume(_ volume: Float, for microphone: SystemMicrophone) {
        SystemMicrophoneCatalog.setInputVolume(volume, of: microphone.deviceID)
        let actual = SystemMicrophoneCatalog.inputVolume(of: microphone.deviceID)
        if let index = microphones.firstIndex(where: { $0.id == microphone.id }) {
            microphones[index].volume = actual.value ?? volume
        }
    }

    func startTest(for id: String) {
        stopTest(reason: "switch")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionDenied = false
            beginCapture(id)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permissionDenied = !granted
                    if granted { self.beginCapture(id) }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stopTest(reason: String = "user") {
        guard testingID != nil || session != nil else { return }
        timeoutWork?.cancel()
        timeoutWork = nil
        let running = session
        session = nil
        sampleReceiver = nil
        testingID = nil
        captureQueue.async { running?.stopRunning() }
        AppLogger.shared.write("SYSTEM MIC TEST stop reason=\(reason)")
    }

    func resetClipping(for id: String) {
        guard testingID == id else { readings[id] = nil; return }
        meter.reset()
        readings[id] = nil
    }

    private func beginCapture(_ id: String) {
        guard let device = AVCaptureDevice(uniqueID: id),
              let input = try? AVCaptureDeviceInput(device: device) else {
            AppLogger.shared.write("SYSTEM MIC TEST unavailable")
            return
        }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
        ]
        let receiver = SampleReceiver { [weak self] samples in
            Task { @MainActor in self?.observe(samples, from: id) }
        }
        output.setSampleBufferDelegate(receiver, queue: captureQueue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            AppLogger.shared.write("SYSTEM MIC TEST unavailable")
            return
        }
        session.addInput(input)
        session.addOutput(output)
        meter = MicrophoneLevelMeter()
        lastPublishedAt = 0
        readings[id] = nil
        self.session = session
        sampleReceiver = receiver
        testingID = id
        captureQueue.async { session.startRunning() }
        AppLogger.shared.write("SYSTEM MIC TEST start")
        let work = DispatchWorkItem { [weak self] in self?.stopTest(reason: "timeout") }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.testTimeout, execute: work)
    }

    private func observe(_ samples: [Int16], from id: String) {
        guard testingID == id else { return }
        let now = ProcessInfo.processInfo.systemUptime
        meter.observe(samples, now: now)
        if now - lastPublishedAt >= Self.publishInterval {
            lastPublishedAt = now
            readings[id] = meter.reading
        }
    }
}

/// Copies 16-bit samples out of each capture buffer on the capture queue.
private final class SampleReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let deliver: ([Int16]) -> Void

    init(deliver: @escaping ([Int16]) -> Void) {
        self.deliver = deliver
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        // Only the contiguous run at offset 0 is safe to read through the pointer; it is
        // plenty for a level meter.
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length,
                                          totalLengthOut: nil, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer, length >= 2 else { return }
        let count = length / MemoryLayout<Int16>.size
        let samples = pointer.withMemoryRebound(to: Int16.self, capacity: count) {
            Array(UnsafeBufferPointer(start: $0, count: count))
        }
        deliver(samples)
    }
}
