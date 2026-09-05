import XCTest
@testable import VocaMac

final class FailedAudioDumpTests: XCTestCase {
    func testWavDataIsAReadableSixteenBitMonoContainer() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let data = FailedAudioDump.wavData(from: samples, sampleRate: 16_000)

        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")

        func int16(at offset: Int) -> Int16 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int16.self) }
        }
        XCTAssertEqual(int16(at: 22), 1, "mono")
        XCTAssertEqual(int16(at: 34), 16, "bits per sample")
        XCTAssertEqual(int16(at: 44), 0)
        XCTAssertEqual(int16(at: 46), 16_383)
        XCTAssertEqual(int16(at: 50), 32_767)
        XCTAssertEqual(int16(at: 52), -32_767)
    }

    func testDumpsAreOffUnlessTurnedOn() {
        UserDefaults.standard.removeObject(forKey: FailedAudioDump.preferenceKey)
        XCTAssertFalse(FailedAudioDump.isEnabled)
        XCTAssertNil(FailedAudioDump.save([0.1, 0.2], model: "canary-180m-flash"))
    }
}

    func testDumpFilenamesDoNotCollideWithinTheSameSecond() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let left = FailedAudioDump.makeFilename(
            model: "canary-180m-flash", date: date, uniqueID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        let right = FailedAudioDump.makeFilename(
            model: "canary-180m-flash", date: date, uniqueID: "ffffffff-1111-2222-3333-444444444444"
        )
        XCTAssertNotEqual(left, right)
        XCTAssertTrue(left.hasSuffix("-canary-180m-flash.wav"))
        XCTAssertTrue(left.contains("aaaaaaaa"))
        XCTAssertTrue(right.contains("ffffffff"))
    }

    func testDumpFilenameSanitizesModelPathCharacters() {
        let name = FailedAudioDump.makeFilename(
            model: "path/with:chars",
            date: Date(timeIntervalSince1970: 0),
            uniqueID: "12345678-0000-0000-0000-000000000000"
        )
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasSuffix("-path-with-chars.wav"))
    }

