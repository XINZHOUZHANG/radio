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
}
