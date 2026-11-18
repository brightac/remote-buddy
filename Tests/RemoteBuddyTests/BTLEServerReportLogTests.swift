import Foundation
import Testing
@testable import RemoteBuddy

@Suite("BTLEServer report log")
struct BTLEServerReportLogTests {
    private let remote = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let keyboard = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private func indication(_ id: UUID, at time: TimeInterval) -> BTLEServerReportLog.Line {
        BTLEServerReportLog.parse(
            message: "Dispatching GATT indication for device \"\(id.uuidString)\" to session \"com.apple.BTLEServer-central-634-17\"",
            timestamp: time
        )!
    }

    private func report(_ text: String, at time: TimeInterval) -> BTLEServerReportLog.Line {
        BTLEServerReportLog.parse(message: "Updated input report for ID #\(text)", timestamp: time)!
    }

    @Test func parsesTwoByteConsumerReport() {
        let line = BTLEServerReportLog.parse(
            message: "Updated input report for ID #2: {length = 2, bytes = 0x4200}", timestamp: 1)
        #expect(line == .report(.init(reportID: 2, data: Data([0x42, 0x00])), timestamp: 1))
    }

    @Test func redactedPayloadIsIgnored() {
        #expect(BTLEServerReportLog.parse(
            message: "Updated input report for ID #2: <private>", timestamp: 1) == nil)
    }

    @Test func abbreviatedPayloadIsIgnored() {
        #expect(BTLEServerReportLog.parse(
            message: "Updated input report for ID #1: {length = 20, bytes = 0x00000000 ... 00000000}", timestamp: 1) == nil)
    }

    @Test func parsesNdjsonTimestamp() {
        let line = #"{"timestamp":"2026-11-18 23:39:30.485000+0800","eventMessage":"Updated input report for ID #2: {length = 2, bytes = 0x2402}"}"#
        guard case let .report(parsed, time)? = BTLEServerReportLog.parse(ndjsonLine: line) else {
            Issue.record("not parsed"); return
        }
        #expect(parsed.data == Data([0x24, 0x02]))
        #expect(abs(time - 1_795_016_370.485) < 0.001)
    }

    @Test func forwardsOnlyReportsAttributedToTheRemote() {
        var attributor = BTLEServerReportLog.Attributor()
        #expect(attributor.accept(indication(remote, at: 10.000), peripherals: [remote]) == nil)
        #expect(attributor.accept(report("2: {length = 2, bytes = 0x4500}", at: 10.007), peripherals: [remote])
            == .init(reportID: 2, data: Data([0x45, 0x00])))

        _ = attributor.accept(indication(keyboard, at: 11.000), peripherals: [remote])
        #expect(attributor.accept(report("2: {length = 2, bytes = 0xe900}", at: 11.004), peripherals: [remote]) == nil)
    }

    @Test func staleIndicationDoesNotAttributeLaterReport() {
        var attributor = BTLEServerReportLog.Attributor()
        _ = attributor.accept(indication(remote, at: 10.0), peripherals: [remote])
        #expect(attributor.accept(report("2: {length = 2, bytes = 0x4200}", at: 10.5), peripherals: [remote]) == nil)
    }

    @Test func eachIndicationAttributesOneReport() {
        var attributor = BTLEServerReportLog.Attributor()
        _ = attributor.accept(indication(remote, at: 10.0), peripherals: [remote])
        #expect(attributor.accept(report("2: {length = 2, bytes = 0x4200}", at: 10.005), peripherals: [remote]) != nil)
        #expect(attributor.accept(report("2: {length = 2, bytes = 0x0000}", at: 10.010), peripherals: [remote]) == nil)
    }

    @Test func recoveredReportsDecodeToRemoteButtons() {
        let cases: [(UInt8, UInt8, RemoteButton)] = [
            (0x42, 0x00, .up), (0x43, 0x00, .down), (0x44, 0x00, .left), (0x45, 0x00, .right),
            (0x41, 0x00, .ok), (0x24, 0x02, .back), (0x23, 0x02, .home), (0xE2, 0x00, .mute),
            (0x77, 0x00, .youtube), (0x78, 0x00, .netflix), (0x9E, 0x01, .power), (0x89, 0x01, .input),
            (0xE9, 0x00, .volumeUp), (0xEA, 0x00, .volumeDown),
        ]
        for (low, high, button) in cases {
            #expect(G9N9NProtocol.usages(reportID: 2, data: Data([low, high])) == [button.hidUsage])
        }
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data([0, 0])) == [])
    }
}
