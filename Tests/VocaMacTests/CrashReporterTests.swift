// CrashReporterTests.swift
// VocaMac Tests
//
// Reading macOS crash reports, building the pre-filled issue, and finding
// reports that haven't been shown yet.

import XCTest
@testable import VocaMac

final class CrashReporterTests: XCTestCase {

    /// A trimmed `.ips` in the shape macOS 14–27 write: a JSON header line,
    /// then a JSON body.
    static func ips(
        version: String = "1.1.0",
        reason: String? = "-[NSTaggedPointerString objectForKey:]: unrecognized selector sent to instance 0x91",
        withAppSymbols: Bool = true
    ) -> String {
        let header = #"{"app_name":"VocaMac","timestamp":"2026-10-07 00:02:58.00 +0530","app_version":"\#(version)","bug_type":"309","os_version":"macOS 27.0.1 (26A434)","incident_id":"698D6E5A","name":"VocaMac"}"#
        let reasonJSON = reason.map { #","exceptionReason":{"composed_message":"\#($0)","name":"NSInvalidArgumentException"}"# } ?? ""
        let appFrame = withAppSymbols
            ? #"{"imageOffset":4096,"symbol":"FileDownloader.downloadOnce(from:to:)","symbolLocation":120,"imageIndex":1}"#
            : #"{"imageOffset":4096,"imageIndex":1}"#
        let body = """
        {
          "modelCode" : "MacBookPro18,1",
          "procPath" : "/Users/someone/Applications/VocaMac.app/Contents/MacOS/VocaMac",
          "exception" : {"type":"EXC_CRASH","signal":"SIGABRT"},
          "termination" : {"indicator":"Abort trap: 6"}\(reasonJSON),
          "faultingThread" : 1,
          "threads" : [
            {"frames":[{"imageOffset":1,"symbol":"mach_msg2_trap","symbolLocation":8,"imageIndex":0}]},
            {"triggered":true,"frames":[
              {"imageOffset":38480,"symbol":"__pthread_kill","symbolLocation":8,"imageIndex":0},
              \(appFrame)
            ]}
          ],
          "lastExceptionBacktrace" : [
            {"imageOffset":99852,"symbol":"objc_exception_throw","symbolLocation":88,"imageIndex":0}
          ],
          "usedImages" : [
            {"name":"libsystem_kernel.dylib","uuid":"f63bf418","path":"/usr/lib/system/libsystem_kernel.dylib"},
            {"name":"VocaMac","uuid":"aaaa-bbbb","path":"/Users/someone/Applications/VocaMac.app/Contents/MacOS/VocaMac"}
          ]
        }
        """
        return header + "\n" + body
    }

    // MARK: - Parsing

    func testParsesTheCrashedThreadAndException() throws {
        let report = try XCTUnwrap(CrashReport.parse(Self.ips()))
        XCTAssertEqual(report.appVersion, "1.1.0")
        XCTAssertEqual(report.osVersion, "macOS 27.0.1 (26A434)")
        XCTAssertEqual(report.macModel, "MacBookPro18,1")
        XCTAssertEqual(report.summary, "EXC_CRASH (SIGABRT)")
        XCTAssertEqual(report.crashedThread, 1)
        XCTAssertEqual(report.frames.map(\.image), ["libsystem_kernel.dylib", "VocaMac"])
        XCTAssertEqual(report.frames.last?.line, "VocaMac  FileDownloader.downloadOnce(from:to:) + 120")
        XCTAssertEqual(report.exceptionFrames.first?.symbol, "objc_exception_throw")
        XCTAssertEqual(report.binaryUUID, "aaaa-bbbb")
        XCTAssertEqual(report.firstAppFrame?.symbol, "FileDownloader.downloadOnce(from:to:)")
    }

    func testFallsBackToTheTerminationReason() throws {
        let report = try XCTUnwrap(CrashReport.parse(Self.ips(reason: nil)))
        XCTAssertEqual(report.reason, "Abort trap: 6")
    }

    func testFramesWithoutSymbolsShowTheImageOffset() throws {
        let report = try XCTUnwrap(CrashReport.parse(Self.ips(withAppSymbols: false)))
        XCTAssertEqual(report.frames.last?.line, "VocaMac  0x1000")
        XCTAssertNil(report.firstAppFrame)
    }

    func testRejectsTextThatIsNotACrashReport() {
        XCTAssertNil(CrashReport.parse(""))
        XCTAssertNil(CrashReport.parse("hello"))
        XCTAssertNil(CrashReport.parse("{}\nnot json"))
    }

    func testRedactsHomeFolders() {
        XCTAssertEqual(
            CrashReport.redact("could not open /Users/jane.doe/Library/foo.wav"),
            "could not open ~/Library/foo.wav"
        )
        XCTAssertEqual(CrashReport.redact(String(repeating: "x", count: 600)).count, 501)
    }

    // MARK: - Issue

    func testIssuePrefillsTheBugReportForm() throws {
        let report = try XCTUnwrap(CrashReport.parse(Self.ips()))
        let url = CrashIssue.url(for: report)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(value("template"), "bug_report.yml")
        XCTAssertEqual(value("title"), "Crash: EXC_CRASH (SIGABRT) in FileDownloader.downloadOnce(from:to:)")
        XCTAssertEqual(value("version"), "1.1.0")
        XCTAssertEqual(value("macos"), "macOS 27.0.1 (26A434), MacBookPro18,1")
        let logs = try XCTUnwrap(value("logs"))
        XCTAssertTrue(logs.contains("Reason: -[NSTaggedPointerString objectForKey:]"))
        XCTAssertTrue(logs.contains("1  VocaMac  FileDownloader.downloadOnce(from:to:) + 120"))
        XCTAssertTrue(logs.contains("VocaMac binary UUID: aaaa-bbbb"))
        // The home folder in procPath and image paths never reaches the issue.
        XCTAssertFalse(url.absoluteString.contains("someone"))
    }

    func testLongStacksAreTrimmedToFitAURL() throws {
        var report = try XCTUnwrap(CrashReport.parse(Self.ips()))
        let frame = CrashReport.Frame(image: "VocaMac", symbol: String(repeating: "deeplyNestedGenericSymbol", count: 12), offset: 4)
        report.frames = Array(repeating: frame, count: CrashReport.maxFrames)
        report.exceptionFrames = report.frames
        let url = CrashIssue.url(for: report)
        XCTAssertLessThanOrEqual(url.absoluteString.count, CrashIssue.maximumURLLength)
        XCTAssertTrue(url.absoluteString.contains("template=bug_report.yml"))
    }

    func testAHugeSymbolIsShortenedInTheTitle() throws {
        var report = try XCTUnwrap(CrashReport.parse(Self.ips()))
        let symbol = String(repeating: "VeryLongGenericSymbol", count: 600)
        report.frames = [CrashReport.Frame(image: "VocaMac", symbol: symbol, offset: 1)]
        report.exceptionFrames = []
        let title = CrashIssue.title(for: report)
        XCTAssertLessThanOrEqual(title.count, 40 + CrashIssue.maximumTitleSymbolLength)
        XCTAssertLessThanOrEqual(CrashIssue.url(for: report).absoluteString.count, CrashIssue.maximumURLLength)
    }

    func testAReasonTooLongForAnyURLFallsBackToTheBareForm() throws {
        var report = try XCTUnwrap(CrashReport.parse(Self.ips()))
        // Past the redaction limit on purpose: the fallback must still fit.
        report.reason = String(repeating: "%", count: 20_000)
        let url = CrashIssue.url(for: report)
        XCTAssertLessThanOrEqual(url.absoluteString.count, CrashIssue.maximumURLLength)
        XCTAssertTrue(url.absoluteString.contains("template=bug_report.yml"))
    }

    // MARK: - Finding reports

    private func makeFinder() throws -> (CrashReportFinder, URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashReporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suite = "CrashReporterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (CrashReportFinder(directory: directory, defaults: defaults), directory, defaults)
    }

    private func write(_ name: String, in directory: URL, modified: Date, text: String = CrashReporterTests.ips()) throws {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testOnlyVocaMacReportsCount() {
        XCTAssertTrue(CrashReportFinder.isVocaMacReport("VocaMac-2026-10-07-000258.ips"))
        XCTAssertTrue(CrashReportFinder.isVocaMacReport("VocaMac-2026-10-07-000258-1.ips"))
        XCTAssertFalse(CrashReportFinder.isVocaMacReport("xctest-2026-10-07-000258.ips"))
        XCTAssertFalse(CrashReportFinder.isVocaMacReport("VocaMacHelper-2026-10-07-000258.ips"))
        XCTAssertFalse(CrashReportFinder.isVocaMacReport("VocaMac-2026-10-07-000258.diag"))
    }

    func testFirstRunOnlyRecordsABaseline() throws {
        let (finder, directory, defaults) = try makeFinder()
        let now = Date()
        try write("VocaMac-old.ips", in: directory, modified: now.addingTimeInterval(-3_600))

        XCTAssertNil(finder.newestUnseenReport(now: now))
        XCTAssertEqual(defaults.object(forKey: CrashReportFinder.lastSeenKey) as? Date, now)
    }

    func testFindsTheNewestUnseenReportUntilItIsMarkedSeen() throws {
        let (finder, directory, _) = try makeFinder()
        let start = Date().addingTimeInterval(-100)
        XCTAssertNil(finder.newestUnseenReport(now: start))

        try write("VocaMac-a.ips", in: directory, modified: start.addingTimeInterval(10), text: Self.ips(version: "1.0.0"))
        try write("VocaMac-b.ips", in: directory, modified: start.addingTimeInterval(20), text: Self.ips(version: "1.1.0"))
        try write("Safari-c.ips", in: directory, modified: start.addingTimeInterval(30))

        let pending = try XCTUnwrap(finder.newestUnseenReport())
        XCTAssertEqual(pending.fileURL.lastPathComponent, "VocaMac-b.ips")
        XCTAssertEqual(pending.report.appVersion, "1.1.0")

        finder.markSeen(through: pending.modified)
        XCTAssertNil(finder.newestUnseenReport(), "Older reports aren't offered once a newer one was")
    }

    func testUnreadableReportsAreSkippedOnce() throws {
        let (finder, directory, _) = try makeFinder()
        let start = Date().addingTimeInterval(-100)
        XCTAssertNil(finder.newestUnseenReport(now: start))
        try write("VocaMac-broken.ips", in: directory, modified: start.addingTimeInterval(10), text: "garbage")

        XCTAssertNil(finder.newestUnseenReport())
        try write("VocaMac-good.ips", in: directory, modified: start.addingTimeInterval(5))
        XCTAssertNil(finder.newestUnseenReport(), "Marked seen through the unreadable one")
    }

    // MARK: - AppState

    @MainActor
    func testAppStateOffersThenForgetsTheReport() async throws {
        let (finder, directory, _) = try makeFinder()
        let start = Date().addingTimeInterval(-100)
        XCTAssertNil(finder.newestUnseenReport(now: start))
        try write("VocaMac-x.ips", in: directory, modified: start.addingTimeInterval(10))

        let (appState, _) = AppState.makeTestState(crashReportFinder: finder)
        await appState.checkForCrashReport()
        XCTAssertEqual(appState.pendingCrashReport?.fileURL.lastPathComponent, "VocaMac-x.ips")

        appState.dismissPendingCrash()
        XCTAssertNil(appState.pendingCrashReport)
        await appState.checkForCrashReport()
        XCTAssertNil(appState.pendingCrashReport)
    }

    @MainActor
    func testReportWaitsForADictationToFinish() async throws {
        let (finder, directory, _) = try makeFinder()
        let start = Date().addingTimeInterval(-100)
        XCTAssertNil(finder.newestUnseenReport(now: start))
        try write("VocaMac-y.ips", in: directory, modified: start.addingTimeInterval(10))
        let (appState, _) = AppState.makeTestState(crashReportFinder: finder)
        await appState.checkForCrashReport()
        await appState.startRecording()

        var opened = 0
        XCTAssertFalse(appState.canReportPendingCrash)
        appState.reportPendingCrash { _ in opened += 1; return false }
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(appState.appStatus, .recording, "The recording keeps its controls")
        XCTAssertNotNil(appState.pendingCrashReport)
        await appState.cancelRecording()

        // Afterwards a browser that won't open keeps the card.
        appState.reportPendingCrash { _ in opened += 1; return false }
        XCTAssertEqual(opened, 1)
        XCTAssertNotNil(appState.pendingCrashReport)
    }
}
