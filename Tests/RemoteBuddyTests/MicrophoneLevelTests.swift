import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Microphone level meter")
struct MicrophoneLevelMeterTests {
    @Test func silenceSitsAtTheFloor() {
        var meter = MicrophoneLevelMeter()
        meter.observe(Array(repeating: 0, count: 320), now: 1)
        #expect(meter.reading.level == MicrophoneLevelReading.floor)
        #expect(meter.reading.clippedSamples == 0)
    }

    @Test func fullScaleSquareWaveReadsZeroAndClips() {
        var meter = MicrophoneLevelMeter()
        meter.observe((0..<320).map { $0 % 2 == 0 ? Int16.max : Int16.min }, now: 1)
        #expect(abs(meter.reading.level) < 0.01)
        #expect(meter.reading.clippedSamples == 320)
    }

    @Test func halfScaleIsAboutMinusSix() {
        var meter = MicrophoneLevelMeter()
        meter.observe(Array(repeating: 16_384, count: 320), now: 1)
        #expect(abs(meter.reading.level - -6.02) < 0.05)
    }

    @Test func levelRisesAtOnceAndFallsSlowly() {
        var meter = MicrophoneLevelMeter()
        meter.observe(Array(repeating: 16_384, count: 320), now: 1)
        meter.observe(Array(repeating: 0, count: 320), now: 1.25)
        // 0.25 s at 24 dB/s releases 6 dB.
        #expect(abs(meter.reading.level - -12.02) < 0.05)
        // The peak is held for a second.
        #expect(abs(meter.reading.peak - -6.02) < 0.05)
        meter.observe(Array(repeating: 0, count: 320), now: 2.5)
        #expect(meter.reading.peak == MicrophoneLevelReading.floor)
    }
}

@Suite("Microphone test") @MainActor
struct MicrophoneTestTests {
    @Test func testSuppressesTheVoiceKeyForTheWholeSession() {
        let monitor = MicrophoneLevelMonitor()
        var posted: [Bool] = []
        let trigger = VoiceTapTrigger(selectedMode: { .function },
                                      isSuppressed: { monitor.isTestingSnapshot },
                                      setKey: { posted.append($1); return true })
        let remote = UUID()
        monitor.startTest(for: remote)
        #expect(trigger.setPressed(true))
        // Ending the test mid-session must not send a lone release.
        monitor.stopTest()
        #expect(trigger.setPressed(false))
        trigger.reset()
        #expect(posted.isEmpty)

        #expect(trigger.setPressed(true))
        #expect(trigger.setPressed(false))
        #expect(posted == [true, false])
    }

    @Test func levelsArePublishedPerRemote() {
        var time: TimeInterval = 10
        let monitor = MicrophoneLevelMonitor(now: { time })
        let first = UUID(), second = UUID()
        monitor.observe(Array(repeating: 16_384, count: 320), from: first)
        time += 0.1
        monitor.observe(Array(repeating: 0, count: 320), from: second)
        #expect(monitor.readings[first] != nil)
        #expect(monitor.readings[second]?.level == MicrophoneLevelReading.floor)
    }
}
