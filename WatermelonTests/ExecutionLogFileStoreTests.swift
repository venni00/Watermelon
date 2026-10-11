import XCTest
@testable import Watermelon

final class ExecutionLogFileStoreTests: XCTestCase {
    func testExportAndDeleteKeepTraceWithItsLog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("session.log")
        let trace = ExecutionLogFileStore.restoreTraceURL(for: log)
        try Data().write(to: log)
        try Data().write(to: trace)
        XCTAssertEqual(ExecutionLogFileStore.exportURLs(for: log), [log, trace])
        ExecutionLogFileStore.removeSession(at: log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trace.path))
    }

    func testSameSecondSessionsAreUniqueAndOldNamesRemainReadable() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = ExecutionLogFileStore.beginSession(kind: .manual, startedAt: date)
        let second = ExecutionLogFileStore.beginSession(kind: .manual, startedAt: date)
        XCTAssertNotEqual(first.fileURL, second.fileURL)
        XCTAssertEqual(ExecutionLogSessionInfo.parse(url: first.fileURL, kind: .manual)?.startedAt, date)
        let legacy = first.fileURL.deletingLastPathComponent().appendingPathComponent(
            ExecutionLogFileStore.fileNameFormatter.string(from: date) + ".log")
        XCTAssertEqual(ExecutionLogSessionInfo.parse(url: legacy, kind: .manual)?.startedAt, date)
        await first.finalize()
        await second.finalize()
    }

    func testHistorySizeIncludesTrace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("20261011T010000Z.log")
        try Data(repeating: 0, count: 10).write(to: url)
        try Data(repeating: 0, count: 30).write(to: ExecutionLogFileStore.restoreTraceURL(for: url))
        XCTAssertEqual(ExecutionLogSessionInfo.parse(url: url, kind: .manual)?.sizeBytes, 40)
    }
}
