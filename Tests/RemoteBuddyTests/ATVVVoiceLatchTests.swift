import Foundation
import Testing
@testable import RemoteBuddy

@Suite("ATVV tap-to-talk latch")
struct ATVVVoiceLatchTests {
    private let hold = ATVVVoiceLatch.holdToTalkReason
    private let host = ATVVVoiceLatch.hostOpenReason

    // Sequence captured on a G9N9N 0x011B remote:
    // 04 03 02 3B (press) → 00 02 (release) → host 0C 00 → 04 00 02 00 (host stream) …
    // 04 03 02 3C (second press) → 00 02 (release)
    @Test func shortPressLatchesAndSecondPressEnds() {
        var latch = ATVVVoiceLatch()
        #expect(latch.remoteStart(reason: hold, enabled: true, now: 0) == .start)
        #expect(latch.remoteStop(now: 1.3) == .reopen)
        #expect(latch.isLatched)
        #expect(latch.remoteStart(reason: host, enabled: true, now: 1.33) == .continueStream)
        #expect(latch.phase == .latched)
        #expect(latch.remoteStart(reason: hold, enabled: true, now: 46) == .endLatch)
        #expect(!latch.isLatched)
        #expect(latch.remoteStop(now: 46.8) == .ignore)
        #expect(latch.phase == .idle)
    }

    @Test func longHoldKeepsHoldToTalk() {
        var latch = ATVVVoiceLatch()
        _ = latch.remoteStart(reason: hold, enabled: true, now: 0)
        #expect(latch.remoteStop(now: 6.3) == .stop)
        #expect(latch.phase == .idle)
    }

    @Test func disabledLatchNeverReopens() {
        var latch = ATVVVoiceLatch()
        #expect(latch.remoteStart(reason: hold, enabled: false, now: 0) == .start)
        #expect(latch.remoteStop(now: 1.3) == .stop)
    }

    @Test func otherKeyEndsLatchAndAbsorbsTheRemoteStop() {
        var latch = ATVVVoiceLatch()
        _ = latch.remoteStart(reason: hold, enabled: true, now: 0)
        _ = latch.remoteStop(now: 1.3)
        _ = latch.remoteStart(reason: host, enabled: true, now: 1.33)
        let ended = latch.end(now: 10)
        let endedAgain = latch.end(now: 10.1)
        #expect(ended)
        #expect(!endedAgain)
        #expect(latch.remoteStop(now: 10.2) == .ignore)
        // The next press after ending starts fresh.
        #expect(latch.remoteStart(reason: hold, enabled: true, now: 20) == .start)
    }

    @Test func endingExpiresWhenTheRemoteNeverConfirms() {
        var latch = ATVVVoiceLatch()
        _ = latch.remoteStart(reason: hold, enabled: true, now: 0)
        _ = latch.remoteStop(now: 1.3)
        _ = latch.remoteStart(reason: host, enabled: true, now: 1.33)
        _ = latch.end(now: 10)
        #expect(latch.remoteStart(reason: hold, enabled: true, now: 14) == .start)
    }

    @Test func reopenTimesOutWithoutHostStream() {
        var latch = ATVVVoiceLatch()
        _ = latch.remoteStart(reason: hold, enabled: true, now: 0)
        _ = latch.remoteStop(now: 1.3)
        let early = latch.reopenTimedOut(now: 1.5)
        let late = latch.reopenTimedOut(now: 2.0)
        #expect(!early)
        #expect(late)
        #expect(latch.phase == .idle)
    }

    @Test func pressDuringReopenEndsInsteadOfLatching() {
        var latch = ATVVVoiceLatch()
        _ = latch.remoteStart(reason: hold, enabled: true, now: 0)
        _ = latch.remoteStop(now: 1.3)
        #expect(latch.remoteStart(reason: hold, enabled: true, now: 1.4) == .endLatch)
    }

    private func batch(_ level: Int16) -> [Int16] { [Int16](repeating: level, count: 160) }

    // Levels from a hardware session: speech 1,100–4,400, room noise 250–350.
    @Test func silenceDetectorUsesTheMeasuredNoiseFloor() {
        var detector = ATVVLatchSilenceDetector()
        #expect(!detector.isSilent(now: 100))
        detector.begin(now: 0)
        detector.observe(batch(3_000), now: 1)
        detector.observe(batch(1_200), now: 3)
        for second in 4...20 { detector.observe(batch(second.isMultiple(of: 2) ? 260 : 350), now: Double(second)) }
        #expect(detector.speechThresholdRMS == 800)
        detector.observe(batch(1_500), now: 21)  // speech after the floor settled counts
        #expect(!detector.isSilent(now: 32.9))
        #expect(detector.isSilent(now: 33))
    }

    @Test func continuousSpeechBeforeAnyPauseStillCounts() {
        var detector = ATVVLatchSilenceDetector()
        detector.begin(now: 0)
        for second in 1...20 { detector.observe(batch(second.isMultiple(of: 2) ? 1_100 : 2_600), now: Double(second)) }
        #expect(detector.speechThresholdRMS == 2_000)
        #expect(!detector.isSilent(now: 25))
    }

    @Test func noisyRoomRaisesTheThresholdWithinBounds() {
        var detector = ATVVLatchSilenceDetector()
        detector.begin(now: 0)
        detector.observe(batch(400), now: 1)
        #expect(detector.speechThresholdRMS == 1_200)
        detector.observe(batch(1_000), now: 2)
        #expect(detector.isSilent(now: 12))
    }
}
