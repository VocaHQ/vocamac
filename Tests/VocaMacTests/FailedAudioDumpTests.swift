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
