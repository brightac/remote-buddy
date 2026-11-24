import SwiftUI

/// Live level bar for one remote microphone, with a test switch that keeps the voice key
/// from opening the input method while the user speaks to watch the level.
struct MicrophoneTestPanel: View {
    @ObservedObject var monitor: MicrophoneLevelMonitor
    let identifier: UUID
    let isConnected: Bool
    /// Runs before a test starts, so only one microphone is tested at a time.
    var onStart: () -> Void = {}

    var body: some View {
        let isTesting = monitor.testingIdentifier == identifier
        MicrophoneMeterPanel(
            reading: monitor.readings[identifier],
            isTesting: isTesting,
            canStart: isConnected,
            hintKey: "audio.mic_test.hint",
            testingHintKey: "audio.mic_test.testing_hint",
            onToggle: {
                if isTesting {
                    monitor.stopTest()
                } else {
                    onStart()
                    monitor.startTest(for: identifier)
                }
            },
            onResetClipping: { monitor.resetClipping(for: identifier) }
        )
    }
}

/// Title row, test switch, clipping badge, level bar and hint, shared by remote and Mac microphones.
struct MicrophoneMeterPanel: View {
    @EnvironmentObject private var localization: LocalizationStore
    let reading: MicrophoneLevelReading?
    let isTesting: Bool
    let canStart: Bool
    let hintKey: String
    let testingHintKey: String
    let onToggle: () -> Void
    let onResetClipping: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text(localization.text("audio.mic_test.title")).font(.headline)
                Spacer()
                if let reading, reading.clippedSamples > 0 {
                    Button(action: onResetClipping) {
                        Label(localization.text("audio.mic_test.clipped"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .help(localization.text("audio.mic_test.clipped_help"))
                }
                Button(action: onToggle) {
                    Label(localization.text(isTesting ? "audio.mic_test.stop" : "audio.mic_test.start"),
                          systemImage: isTesting ? "stop.fill" : "waveform")
                }
                .compatibilityButtonStyle(isTesting ? .prominent : .standard)
                .disabled(!canStart && !isTesting)
                .accessibilityIdentifier("connection.mic-test.toggle")
            }
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in
                MicrophoneLevelBar(reading: reading, now: ProcessInfo.processInfo.systemUptime)
            }
            .frame(height: 30)
            Text(localization.text(isTesting ? testingHintKey : hintKey))
                .font(.caption)
                .foregroundStyle(isTesting ? Color.accentColor : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Horizontal meter from -60 dBFS to 0 dBFS. Speech for dictation sits best around -30 to
/// -12 dBFS; above -6 the recognizer starts to hear distortion.
struct MicrophoneLevelBar: View {
    let reading: MicrophoneLevelReading?
    let now: TimeInterval

    static let goodRange: ClosedRange<Double> = -30 ... -12
    static let loudFrom: Double = -6
    /// A reading this old means the remote stopped sending audio.
    static let staleAfter: TimeInterval = 0.3

    private var level: Double {
        guard let reading else { return MicrophoneLevelReading.floor }
        let age = max(0, now - reading.updatedAt)
        guard age > Self.staleAfter else { return reading.level }
        return max(MicrophoneLevelReading.floor,
                   reading.level - MicrophoneLevelMeter.releasePerSecond * (age - Self.staleAfter) * 3)
    }

    private var peak: Double? {
        guard let reading, now - reading.updatedAt < MicrophoneLevelMeter.peakHold else { return nil }
        return reading.peak
    }

    private static func fraction(_ dbfs: Double) -> Double {
        min(1, max(0, (dbfs - MicrophoneLevelReading.floor) / -MicrophoneLevelReading.floor))
    }

    private static func color(_ dbfs: Double) -> Color {
        if dbfs >= loudFrom { return .red }
        if dbfs > goodRange.upperBound { return .orange }
        if dbfs >= goodRange.lowerBound { return .green }
        return Color.green.opacity(0.55)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                    // The comfortable speech band, so the target is visible before speaking.
                    Rectangle()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: width * (Self.fraction(Self.goodRange.upperBound) - Self.fraction(Self.goodRange.lowerBound)))
                        .offset(x: width * Self.fraction(Self.goodRange.lowerBound))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Self.color(level))
                        .frame(width: width * Self.fraction(level))
                    if let peak {
                        Rectangle()
                            .fill(Self.color(peak))
                            .frame(width: 2)
                            .offset(x: max(0, width * Self.fraction(peak) - 2))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 12)
            HStack {
                Text("-60 dB")
                Spacer()
                Text(reading == nil ? "—" : String(format: "%.0f dB", level))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                Text("0 dB")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(reading == nil ? "—" : String(format: "%.0f dB", level)))
    }
}
