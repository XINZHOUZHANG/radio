import XCTest
@testable import TX5DRMobile

final class RadioLiteReceiveMonitoringPreferenceTests: XCTestCase {
    func testFirstRadioPageVisitStartsListeningOnlyOnceWithoutAnExplicitChoice() {
        var preference = RadioLiteReceiveMonitoringPreference(
            hasVisitedRadioPage: false,
            explicitUserChoice: nil
        )

        XCTAssertEqual(preference.radioPageDidAppear(), .start)
        XCTAssertTrue(preference.hasVisitedRadioPage)
        XCTAssertEqual(preference.radioPageDidAppear(), .preserve)
    }

    func testLaterRadioPageVisitsRespectAnExplicitStopChoice() {
        var preference = RadioLiteReceiveMonitoringPreference(
            hasVisitedRadioPage: false,
            explicitUserChoice: nil
        )
        _ = preference.radioPageDidAppear()

        preference.recordExplicitUserChoice(false)

        XCTAssertEqual(preference.radioPageDidAppear(), .stop)
        XCTAssertEqual(preference.explicitUserChoice, false)

        var restored = RadioLiteReceiveMonitoringPreference(
            hasVisitedRadioPage: true,
            explicitUserChoice: false
        )
        XCTAssertEqual(restored.radioPageDidAppear(), .stop)
    }

    func testLaterRadioPageVisitsRespectAnExplicitStartChoice() {
        var preference = RadioLiteReceiveMonitoringPreference(
            hasVisitedRadioPage: true,
            explicitUserChoice: true
        )

        XCTAssertEqual(preference.radioPageDidAppear(), .start)
        XCTAssertEqual(preference.explicitUserChoice, true)
    }

    func testExplicitOnRestoresAfterRadioSwitchAndReconnectSuspensions() {
        var intent = RadioLiteReceiveMonitoringIntent()

        intent.setDesired(true)
        XCTAssertTrue(intent.isDesired)
        XCTAssertTrue(intent.shouldMonitor)

        intent.suspend()
        XCTAssertTrue(intent.isDesired, "switching radios must not erase the user's choice")
        XCTAssertFalse(intent.shouldMonitor)
        intent.resume()
        XCTAssertTrue(intent.shouldMonitor, "a successful radio subscription must restore monitoring")

        intent.suspend()
        XCTAssertTrue(intent.isDesired, "connection loss must only suspend monitoring")
        XCTAssertFalse(intent.shouldMonitor)
        intent.resume()
        XCTAssertTrue(intent.shouldMonitor, "a successful reconnect must restore monitoring")
    }

    func testExplicitOffStaysOffAcrossRadioSwitchAndReconnect() {
        var intent = RadioLiteReceiveMonitoringIntent()

        intent.setDesired(false)
        XCTAssertFalse(intent.isDesired)
        XCTAssertFalse(intent.shouldMonitor)

        intent.suspend()
        intent.resume()
        XCTAssertFalse(intent.shouldMonitor, "radio switching must not start explicitly disabled audio")

        intent.suspend()
        intent.resume()
        XCTAssertFalse(intent.shouldMonitor, "reconnect must not start explicitly disabled audio")
    }
}
