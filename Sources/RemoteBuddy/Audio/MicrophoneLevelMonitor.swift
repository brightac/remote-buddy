import Combine
import Foundation

/// One remote microphone's level after gain, in dBFS (0 is full scale).
struct MicrophoneLevelReading: Equatable {
    /// Smoothed RMS level: rises at once, falls slowly so speech reads steadily.
    var level: Double
    /// Highest recent peak, held briefly like a hardware meter.
    var peak: Double
    /// Samples at or near full scale since the reading began; nonzero means the gain is too high.
    var clippedSamples: Int
    var updatedAt: TimeInterval

    static let floor: Double = -60
}

/// Pure level math, kept free of timers and publishing so it can be tested directly.
struct MicrophoneLevelMeter {
    static let releasePerSecond: Double = 24
    static let peakHold: TimeInterval = 1.0
    static let clipThreshold: Int32 = 32_000

    private(set) var reading = MicrophoneLevelReading(
        level: MicrophoneLevelReading.floor, peak: MicrophoneLevelReading.floor,
        clippedSamples: 0, updatedAt: 0)
    private var peakSetAt: TimeInterval = 0

    static func dbfs(_ amplitude: Double) -> Double {
        guard amplitude > 0 else { return MicrophoneLevelReading.floor }
        return max(MicrophoneLevelReading.floor, 20 * log10(amplitude / 32_768))
    }

    mutating func observe(_ samples: [Int16], now: TimeInterval) {
        guard !samples.isEmpty else { return }
        var energy = 0.0
        var maximum: Int32 = 0
        var clipped = 0
        for sample in samples {
            let value = Int32(sample)
            energy += Double(value * value)
            let magnitude = abs(value)
            maximum = max(maximum, magnitude)
            if magnitude >= Self.clipThreshold { clipped += 1 }
        }
        let rms = Self.dbfs((energy / Double(samples.count)).squareRoot())
        let peak = Self.dbfs(Double(maximum))
        let elapsed = reading.updatedAt == 0 ? 0 : max(0, now - reading.updatedAt)
        let released = reading.level - Self.releasePerSecond * elapsed
        reading.level = max(rms, released, MicrophoneLevelReading.floor)
        if peak >= reading.peak || now - peakSetAt > Self.peakHold {
            reading.peak = peak
            peakSetAt = now
        }
        reading.clippedSamples += clipped
        reading.updatedAt = now
    }

    mutating func reset() { self = MicrophoneLevelMeter() }
}

/// Publishes remote microphone levels for the settings page, separately from the app model
/// so a meter redrawing many times a second does not redraw the whole window.
@MainActor
final class MicrophoneLevelMonitor: ObservableObject {
    /// Keyed by the remote's Bluetooth identifier.
    @Published private(set) var readings: [UUID: MicrophoneLevelReading] = [:]
    /// While a test runs the voice key streams audio without pressing the dictation key.
    @Published private(set) var testingIdentifier: UUID?

    static let testTimeout: TimeInterval = 120
    private static let publishInterval: TimeInterval = 1.0 / 20

    private var meters: [UUID: MicrophoneLevelMeter] = [:]
    private var lastPublishedAt: [UUID: TimeInterval] = [:]
    private var testTimeoutWork: DispatchWorkItem?
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    var isTesting: Bool { testingIdentifier != nil }

    /// Readable from any thread; the voice key path consults it outside the main actor.
    nonisolated var isTestingSnapshot: Bool { testingFlag.value }
    private nonisolated let testingFlag = LockedFlag()

    func observe(_ samples: [Int16], from identifier: UUID) {
        let time = now()
        var meter = meters[identifier] ?? MicrophoneLevelMeter()
        meter.observe(samples, now: time)
        meters[identifier] = meter
        if time - (lastPublishedAt[identifier] ?? 0) >= Self.publishInterval {
            lastPublishedAt[identifier] = time
            readings[identifier] = meter.reading
        }
    }

    func startTest(for identifier: UUID) {
        meters[identifier] = MicrophoneLevelMeter()
        readings[identifier] = nil
        testingIdentifier = identifier
        testingFlag.value = true
        AppLogger.shared.write("MIC TEST start")
        testTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopTest(reason: "timeout") }
        testTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.testTimeout, execute: work)
    }

    func stopTest(reason: String = "user") {
        guard testingIdentifier != nil else { return }
        testTimeoutWork?.cancel()
        testTimeoutWork = nil
        testingIdentifier = nil
        testingFlag.value = false
        AppLogger.shared.write("MIC TEST stop reason=\(reason)")
    }

    func resetClipping(for identifier: UUID) {
        guard var meter = meters[identifier] else { return }
        meter.reset()
        meters[identifier] = meter
        readings[identifier] = nil
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
