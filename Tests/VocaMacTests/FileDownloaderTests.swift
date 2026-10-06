// FileDownloaderTests.swift
// VocaMac Tests
//
// Retry decisions, resume-data storage, and a real transfer for the model
// downloader.

import XCTest
@testable import VocaMac

final class FileDownloaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Transient errors

    func testDroppedConnectionsAreTransient() {
        XCTAssertTrue(FileDownloader.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(FileDownloader.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertTrue(FileDownloader.isTransient(URLError(.timedOut)))
    }

    func testServerErrorsAreTransientButClientErrorsAreNot() {
        XCTAssertTrue(FileDownloader.isTransient(FileDownloaderError.badResponse(statusCode: 503)))
        XCTAssertTrue(FileDownloader.isTransient(FileDownloaderError.badResponse(statusCode: 429)))
        XCTAssertFalse(FileDownloader.isTransient(FileDownloaderError.badResponse(statusCode: 404)))
        XCTAssertFalse(FileDownloader.isTransient(FileDownloaderError.badResponse(statusCode: 416)))
    }

    func testOtherErrorsAreNotTransient() {
        XCTAssertFalse(FileDownloader.isTransient(URLError(.cancelled)))
        XCTAssertFalse(FileDownloader.isTransient(URLError(.fileDoesNotExist)))
        XCTAssertFalse(FileDownloader.isTransient(FileDownloaderError.moveFailed(reason: "disk full")))
        XCTAssertFalse(FileDownloader.isTransient(CocoaError(.fileWriteOutOfSpace)))
    }

    // MARK: - Retry decisions

    func testTransientErrorsBackOffThenGiveUp() {
        let error = URLError(.networkConnectionLost)
        XCTAssertEqual(FileDownloader.retryDecision(after: error, attempt: 1, resumed: false, hasResumeData: true), 1)
        XCTAssertEqual(FileDownloader.retryDecision(after: error, attempt: 2, resumed: true, hasResumeData: true), 3)
        XCTAssertEqual(FileDownloader.retryDecision(after: error, attempt: 3, resumed: true, hasResumeData: true), 8)
        XCTAssertNil(FileDownloader.retryDecision(
            after: error, attempt: FileDownloader.maxAttempts, resumed: true, hasResumeData: true
        ))
    }

    func testAFailedResumeStartsOverOnce() {
        let refused = FileDownloaderError.badResponse(statusCode: 416)
        XCTAssertEqual(FileDownloader.retryDecision(after: refused, attempt: 1, resumed: true, hasResumeData: false), 0)
        // A fresh download that fails the same way is a real failure.
        XCTAssertNil(FileDownloader.retryDecision(after: refused, attempt: 2, resumed: false, hasResumeData: false))
    }

    func testPermanentErrorsAreNotRetried() {
        XCTAssertNil(FileDownloader.retryDecision(
            after: FileDownloaderError.badResponse(statusCode: 404), attempt: 1, resumed: false, hasResumeData: false
        ))
    }

    // MARK: - Resume store

    func testResumeStoreRoundTripsByURL() {
        let store = DownloadResumeStore(directory: directory)
        let url = URL(string: "https://example.com/models/a.gguf")!
        let other = URL(string: "https://example.com/models/b.gguf")!
        XCTAssertNil(store.load(for: url))

        store.save(Data("partial".utf8), for: url)
        XCTAssertEqual(store.load(for: url), Data("partial".utf8))
        XCTAssertNil(store.load(for: other))

        store.remove(for: url)
        XCTAssertNil(store.load(for: url))
    }

    func testResumeStoreWithoutDirectoryKeepsNothing() {
        let store = DownloadResumeStore(directory: nil)
        let url = URL(string: "https://example.com/a")!
        store.save(Data("x".utf8), for: url)
        XCTAssertNil(store.load(for: url))
    }

    func testOnlyPropertyListDictionariesAreUsableResumeData() throws {
        XCTAssertNil(FileDownloader.usableResumeData(Data("stale".utf8)))
        XCTAssertNil(FileDownloader.usableResumeData(Data()))
        let array = try PropertyListSerialization.data(fromPropertyList: ["a"], format: .binary, options: 0)
        XCTAssertNil(FileDownloader.usableResumeData(array))
        let dictionary = try PropertyListSerialization.data(
            fromPropertyList: ["NSURLSessionResumeBytesReceived": 10], format: .binary, options: 0
        )
        XCTAssertEqual(FileDownloader.usableResumeData(dictionary), dictionary)
    }

    // MARK: - Transfers

    func testDownloadCopiesTheFileAndClearsResumeData() async throws {
        let source = directory.appendingPathComponent("source.bin")
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        try payload.write(to: source)
        let destination = directory.appendingPathComponent("out.bin")
        let store = DownloadResumeStore(directory: directory.appendingPathComponent("resume"))
        store.save(Data("stale".utf8), for: source)

        // Stale resume data cannot be honoured; the download starts over.
        try await FileDownloader.download(from: source, to: destination, resumeStore: store)

        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertNil(store.load(for: source))
    }

    func testResumeDataURLSessionCannotReadStartsOver() async throws {
        let source = directory.appendingPathComponent("source.bin")
        let payload = Data(repeating: 7, count: 2048)
        try payload.write(to: source)
        let destination = directory.appendingPathComponent("out.bin")
        let store = DownloadResumeStore(directory: directory.appendingPathComponent("resume"))
        let bogus = try PropertyListSerialization.data(
            fromPropertyList: ["unexpected": "shape"], format: .binary, options: 0
        )
        store.save(bogus, for: source)

        try await FileDownloader.download(from: source, to: destination, resumeStore: store)

        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertNil(store.load(for: source))
    }

    func testMissingSourceFailsWithoutRetrying() async {
        let source = directory.appendingPathComponent("missing.bin")
        let destination = directory.appendingPathComponent("out.bin")
        let store = DownloadResumeStore(directory: directory.appendingPathComponent("resume"))
        let started = Date()
        do {
            try await FileDownloader.download(from: source, to: destination, resumeStore: store)
            XCTFail("Expected the download to fail")
        } catch {
            XCTAssertFalse(FileDownloader.isTransient(error))
        }
        // No backoff sleeps were taken.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
