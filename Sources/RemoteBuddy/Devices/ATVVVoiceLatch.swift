import Foundation

/// Tap-to-talk for remotes whose firmware only offers ATVV hold-to-talk.
///
/// Some G9N9N batches answer every GET_CAPS with interaction model 0x03 and
/// send AUDIO_STOP when the voice key is released. They do accept a host
/// MIC_OPEN right afterwards and keep streaming until the host closes the
/// microphone. So a short press is latched: on the remote's stop the host
/// reopens the microphone and the voice session continues; the next voice
/// press, any remote key, or a long silence ends it.
///
/// A press held longer than `tapThreshold` keeps ordinary hold-to-talk.
struct ATVVVoiceLatch: Equatable {
    enum Phase: Equatable {
        case idle
        /// Remote started a hold-to-talk stream; a quick stop will latch.
        case armed(startedAt: TimeInterval)
        /// Host sent MIC_OPEN after the remote's stop and awaits AUDIO_START.
        case reopening(since: TimeInterval)
        /// Host-opened stream is running.
        case latched
        /// Host closed the microphone; late remote start/stop lines are absorbed.
        case ending(since: TimeInterval)
    }

    enum StartDecision: Equatable {
        /// Begin a normal stream.
        case start
        /// The host-opened stream replaced the remote's: keep the session and resync audio.
        case continueStream
        /// The voice key was pressed again while latched: end the session.
        case endLatch
        /// Absorb a late start while ending.
        case ignore
    }

    enum StopDecision: Equatable {
        case stop
        /// Short press released: reopen the microphone from the host.
        case reopen
        case ignore
    }

    static let tapThreshold: TimeInterval = 2.0
    static let reopenTimeout: TimeInterval = 0.6
    static let endingTimeout: TimeInterval = 3.0
    static let holdToTalkReason: UInt8 = 0x03
    static let hostOpenReason: UInt8 = 0x00

    private(set) var phase: Phase = .idle

    var isLatched: Bool {
        switch phase {
        case .reopening, .latched: true
        default: false
        }
    }

    mutating func reset() { phase = .idle }

    private mutating func expireEnding(now: TimeInterval) {
        if case let .ending(since) = phase, now - since > Self.endingTimeout { phase = .idle }
    }

    mutating func remoteStart(reason: UInt8, enabled: Bool, now: TimeInterval) -> StartDecision {
        expireEnding(now: now)
        switch phase {
        case .idle, .armed:
            phase = enabled && reason == Self.holdToTalkReason ? .armed(startedAt: now) : .idle
            return .start
        case .reopening:
            guard reason == Self.hostOpenReason else {
                // The user pressed again before the reopen settled: treat it as the end.
                phase = .ending(since: now)
                return .endLatch
            }
            phase = .latched
            return .continueStream
        case .latched:
            phase = .ending(since: now)
            return .endLatch
        case .ending:
            return .ignore
        }
    }

    mutating func remoteStop(now: TimeInterval) -> StopDecision {
        expireEnding(now: now)
        switch phase {
        case let .armed(startedAt) where now - startedAt < Self.tapThreshold:
            phase = .reopening(since: now)
            return .reopen
        case .ending:
            phase = .idle
            return .ignore
        default:
            phase = .idle
            return .stop
        }
    }

    /// The host-initiated reopen did not produce AUDIO_START in time.
    mutating func reopenTimedOut(now: TimeInterval) -> Bool {
        guard case let .reopening(since) = phase, now - since >= Self.reopenTimeout else { return false }
        phase = .idle
        return true
    }

    /// A remote key or silence ends the latched session. Returns false when nothing is latched.
    mutating func end(now: TimeInterval) -> Bool {
        guard isLatched else { return false }
        phase = .ending(since: now)
        return true
    }
}

/// Speech activity for auto-closing a latched session that nobody ends.
///
/// The speech threshold follows the session's noise floor: G9N9N audio with the
/// default +10 dB gain idles around RMS 250–350 while speech reaches 1,000–4,000.
struct ATVVLatchSilenceDetector {
    static let minimumSpeechRMS: Double = 800
    /// Until a pause reveals the real floor, continuous speech must not raise the bar out of reach.
    static let maximumSpeechRMS: Double = 2_000
    static let noiseFloorMultiplier: Double = 3
    static let silenceTimeout: TimeInterval = 12

    private(set) var lastSpeechAt: TimeInterval?
    private(set) var noiseFloorRMS: Double = .infinity
    private(set) var windowMaxRMS: Double = 0
    private(set) var windowMinRMS: Double = .infinity

    var speechThresholdRMS: Double {
        guard noiseFloorRMS.isFinite else { return Self.minimumSpeechRMS }
        return min(Self.maximumSpeechRMS,
                   max(Self.minimumSpeechRMS, noiseFloorRMS * Self.noiseFloorMultiplier))
    }

    mutating func begin(now: TimeInterval) {
        lastSpeechAt = now
        noiseFloorRMS = .infinity
        windowMaxRMS = 0
        windowMinRMS = .infinity
    }

    mutating func observe(_ samples: [Int16], now: TimeInterval) {
        guard !samples.isEmpty else { return }
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = (energy / Double(samples.count)).squareRoot()
        windowMaxRMS = max(windowMaxRMS, rms)
        windowMinRMS = min(windowMinRMS, rms)
        noiseFloorRMS = min(noiseFloorRMS, rms)
        if rms >= speechThresholdRMS { lastSpeechAt = now }
    }

    /// Returns and clears the per-check level window, for diagnostics.
    mutating func takeWindow() -> (min: Int, max: Int)? {
        defer { windowMaxRMS = 0; windowMinRMS = .infinity }
        guard windowMinRMS.isFinite else { return nil }
        return (Int(windowMinRMS), Int(windowMaxRMS))
    }

    func isSilent(now: TimeInterval) -> Bool {
        guard let lastSpeechAt else { return false }
        return now - lastSpeechAt >= Self.silenceTimeout
    }
}
