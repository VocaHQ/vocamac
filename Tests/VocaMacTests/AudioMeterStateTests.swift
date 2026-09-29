import XCTest
import Combine
@testable import VocaMac

@MainActor
final class AudioMeterStateTests: XCTestCase {
    func testMeterDoesNotPublishUnrelatedAppChanges() {
        let (app, _) = AppState.makeTestState()
        var appChanges = 0
        var meterChanges = 0
        let appSubscription = app.objectWillChange.sink { appChanges += 1 }
        let meterSubscription = app.audioMeter.objectWillChange.sink { meterChanges += 1 }
        app.audioLevel = 0.5
        app.audioLevel = 0.5
        app.audioLevel = 0
        XCTAssertEqual(appChanges, 0)
        XCTAssertEqual(meterChanges, 2)
        withExtendedLifetime((appSubscription, meterSubscription)) { }
    }

    func testInvalidLevelsCannotReachViewGeometry() {
        let meter = AudioMeterState()
        for input in [Float.nan, .infinity, -1] {
            meter.update(input)
            XCTAssertEqual(meter.level, 0)
        }
        meter.update(2)
        XCTAssertEqual(meter.level, 1)
    }
}
