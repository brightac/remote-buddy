import Foundation

/// Some G9N9N batches (for example HID VersionNumber 0x011B) declare a 3-byte
/// Consumer Control report 2 (16-bit usage plus an 8-bit button field) but send
/// only the 2-byte usage. macOS BTLEServer logs the received report and then
/// drops it before IOHID, so IOHID input callbacks never fire for these keys.
///
/// This source reads the reports from the unified log instead. It needs the
/// com.apple.bluetooth subsystem private data enabled (a logging configuration
/// profile); without it the payload is "<private>" and nothing is forwarded.
/// bluetoothd logs which peripheral each GATT indication came from right before
/// BTLEServer logs the report, so reports are attributed to a peripheral by
/// pairing the two lines in time. Reports from other BLE HID devices
/// (keyboards, mice) are never forwarded.
enum BTLEServerReportLog {
    struct Report: Equatable {
        let reportID: UInt32
        let data: Data
    }

    enum Line: Equatable {
        case indication(peripheral: UUID, timestamp: TimeInterval)
        case report(Report, timestamp: TimeInterval)
    }

    static let predicate =
        "(process == \"BTLEServer\" AND eventMessage BEGINSWITH \"Updated input report for ID #\") OR " +
        "(process == \"bluetoothd\" AND eventMessage BEGINSWITH \"Dispatching GATT indication for device\" " +
        "AND eventMessage CONTAINS \"BTLEServer\")"

    /// Maximum gap between bluetoothd's dispatch line and BTLEServer's report line.
    /// Observed gaps reach 46 ms, so leave headroom.
    static let attributionWindow: TimeInterval = 0.2

    private static let reportPattern = try! NSRegularExpression(
        pattern: #"^Updated input report for ID #(\d+): \{length = (\d+), bytes = 0x([0-9a-fA-F]+)\}$"#
    )
    private static let indicationPattern = try! NSRegularExpression(
        pattern: #"^Dispatching GATT indication for device "([0-9A-Fa-f-]{36})" to session "#
    )

    /// Parses one `log stream --style ndjson` line.
    static func parse(ndjsonLine: String) -> Line? {
        guard let raw = ndjsonLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let message = object["eventMessage"] as? String,
              let timestampText = object["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampText) else { return nil }
        return parse(message: message, timestamp: timestamp)
    }

    static func parse(message: String, timestamp: TimeInterval) -> Line? {
        let range = NSRange(message.startIndex..., in: message)
        if let match = indicationPattern.firstMatch(in: message, range: range),
           let idRange = Range(match.range(at: 1), in: message),
           let peripheral = UUID(uuidString: String(message[idRange])) {
            return .indication(peripheral: peripheral, timestamp: timestamp)
        }
        guard let match = reportPattern.firstMatch(in: message, range: range),
              let idRange = Range(match.range(at: 1), in: message),
              let lengthRange = Range(match.range(at: 2), in: message),
              let bytesRange = Range(match.range(at: 3), in: message),
              let reportID = UInt32(message[idRange]),
              let length = Int(message[lengthRange]) else { return nil }
        let hex = message[bytesRange]
        // Long payloads are abbreviated by Foundation; only exact short payloads are usable.
        guard length > 0, length <= 16, hex.count == length * 2 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return .report(Report(reportID: reportID, data: Data(bytes)), timestamp: timestamp)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()

    static func parseTimestamp(_ text: String) -> TimeInterval? {
        timestampFormatter.date(from: text)?.timeIntervalSince1970
    }

    /// Pairs indication and report lines and keeps only reports from `peripherals`.
    ///
    /// bluetoothd does not always log a dispatch line for a release, so an all-zero
    /// report with the same ID and length as a forwarded press that is still held is
    /// attributed to the remote even without its own indication.
    struct Attributor {
        private var lastIndication: (peripheral: UUID, timestamp: TimeInterval)?
        private var heldReport: (reportID: UInt32, length: Int)?

        mutating func accept(_ line: Line, peripherals: Set<UUID>) -> Report? {
            switch line {
            case let .indication(peripheral, timestamp):
                lastIndication = (peripheral, timestamp)
                return nil
            case let .report(report, timestamp):
                let last = lastIndication
                lastIndication = nil
                if let last, peripherals.contains(last.peripheral),
                   timestamp - last.timestamp >= -0.005,
                   timestamp - last.timestamp <= attributionWindow {
                    track(report)
                    return report
                }
                if let held = heldReport, held.reportID == report.reportID,
                   held.length == report.data.count, report.data.allSatisfy({ $0 == 0 }) {
                    heldReport = nil
                    return report
                }
                return nil
            }
        }

        private mutating func track(_ report: Report) {
            heldReport = report.data.allSatisfy({ $0 == 0 })
                ? nil
                : (report.reportID, report.data.count)
        }
    }
}

/// Streams attributed reports from `log stream`. Callbacks arrive on the main queue.
final class BTLEServerReportLogSource {
    private let peripherals: () -> Set<UUID>
    private let onReport: (BTLEServerReportLog.Report) -> Void
    private let diagnosticLogger: (String) -> Void
    private let queue = DispatchQueue(label: "RemoteBuddy.BTLEServerReportLog")
    private var process: Process?
    private var stopped = true
    private var attributor = BTLEServerReportLog.Attributor()
    private var buffer = Data()
    private var restartCount = 0

    init(
        peripherals: @escaping () -> Set<UUID>,
        diagnosticLogger: @escaping (String) -> Void,
        onReport: @escaping (BTLEServerReportLog.Report) -> Void
    ) {
        self.peripherals = peripherals
        self.diagnosticLogger = diagnosticLogger
        self.onReport = onReport
    }

    deinit {
        process?.terminationHandler = nil
        process?.terminate()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.stopped else { return }
            self.stopped = false
            self.restartCount = 0
            self.launch()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.process?.terminationHandler = nil
            self.process?.terminate()
            self.process = nil
        }
    }

    private func launch() {
        guard !stopped else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--level", "debug",
                             "--predicate", BTLEServerReportLog.predicate]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        buffer.removeAll()
        attributor = BTLEServerReportLog.Attributor()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(chunk) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard let self, !self.stopped else { return }
                self.restartCount += 1
                let delay = min(30.0, Double(self.restartCount))
                self.diagnosticLogger("HID BTLE_LOG exited restart_in=\(Int(delay))s")
                self.queue.asyncAfter(deadline: .now() + delay) { self.launch() }
            }
        }
        do {
            try process.run()
            self.process = process
            diagnosticLogger("HID BTLE_LOG started")
        } catch {
            diagnosticLogger("HID BTLE_LOG launch_failed error=\(error.localizedDescription)")
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let parsed = BTLEServerReportLog.parse(ndjsonLine: line) else { continue }
            let targets = DispatchQueue.main.sync { peripherals() }
            guard let report = attributor.accept(parsed, peripherals: targets) else { continue }
            restartCount = 0
            DispatchQueue.main.async { [onReport] in onReport(report) }
        }
    }
}
