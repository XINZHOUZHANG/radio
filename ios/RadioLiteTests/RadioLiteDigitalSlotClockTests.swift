import Foundation
import XCTest
@testable import RadioLite

final class RadioLiteDigitalSlotClockTests: XCTestCase {
    func testFT8UsesFifteenSecondUTCSlotsAtAndImmediatelyBeforeABoundary() throws {
        let clock = try XCTUnwrap(RadioLiteDigitalSlotClock(mode: "FT8"))
        XCTAssertEqual(clock.periodSeconds, 15.0, accuracy: 0.000_000_1)

        // Unix time 30.000 is the exact start of UTC slot 2: [30.0, 45.0).
        let boundary = clock.snapshot(at: Date(timeIntervalSince1970: 30.0))
        XCTAssertEqual(boundary.slotIndex, 2)
        XCTAssertEqual(boundary.slotStart.timeIntervalSince1970, 30.0, accuracy: 0.000_000_1)
        XCTAssertEqual(boundary.elapsedSeconds, 0.0, accuracy: 0.000_000_1)
        XCTAssertEqual(boundary.progress, 0.0, accuracy: 0.000_000_1)
        XCTAssertEqual(boundary.remainingSeconds, 15.0, accuracy: 0.000_000_1)
        XCTAssertEqual(boundary.parity, .even)

        // One millisecond before 45.000 remains in slot 2.
        let justBefore = clock.snapshot(at: Date(timeIntervalSince1970: 44.999))
        XCTAssertEqual(justBefore.slotIndex, 2)
        XCTAssertEqual(justBefore.slotStart.timeIntervalSince1970, 30.0, accuracy: 0.000_000_1)
        XCTAssertEqual(justBefore.elapsedSeconds, 14.999, accuracy: 0.000_000_1)
        XCTAssertEqual(justBefore.progress, 0.999_933_333_333, accuracy: 0.000_000_1)
        XCTAssertEqual(justBefore.remainingSeconds, 0.001, accuracy: 0.000_000_1)
        XCTAssertEqual(justBefore.parity, .even)

        let nextBoundary = clock.snapshot(at: Date(timeIntervalSince1970: 45.0))
        XCTAssertEqual(nextBoundary.slotIndex, 3)
        XCTAssertEqual(nextBoundary.slotStart.timeIntervalSince1970, 45.0, accuracy: 0.000_000_1)
        XCTAssertEqual(nextBoundary.elapsedSeconds, 0.0, accuracy: 0.000_000_1)
        XCTAssertEqual(nextBoundary.progress, 0.0, accuracy: 0.000_000_1)
        XCTAssertEqual(nextBoundary.remainingSeconds, 15.0, accuracy: 0.000_000_1)
        XCTAssertEqual(nextBoundary.parity, .odd)
    }

    func testFT4UsesSevenPointFiveSecondUTCSlotsAtAndImmediatelyBeforeABoundary() throws {
        let clock = try XCTUnwrap(RadioLiteDigitalSlotClock(mode: "FT4"))
        XCTAssertEqual(clock.periodSeconds, 7.5, accuracy: 0.000_000_1)

        // Unix time 15.000 is the exact start of UTC slot 2: [15.0, 22.5).
        let boundary = clock.snapshot(at: Date(timeIntervalSince1970: 15.0))
        XCTAssertEqual(boundary.slotIndex, 2)
        XCTAssertEqual(boundary.slotStart.timeIntervalSince1970, 15.0, accuracy: 0.000_000_1)
        XCTAssertEqual(boundary.elapsedSeconds, 0.0, accuracy: 0.000_000_1)
        XCTAssertEqual(boundary.progress, 0.0, accuracy: 0.000_000_1)
        XCTAssertEqual(boundary.remainingSeconds, 7.5, accuracy: 0.000_000_1)
        XCTAssertEqual(boundary.parity, .even)

        // One millisecond before 22.500 remains in slot 2.
        let justBefore = clock.snapshot(at: Date(timeIntervalSince1970: 22.499))
        XCTAssertEqual(justBefore.slotIndex, 2)
        XCTAssertEqual(justBefore.slotStart.timeIntervalSince1970, 15.0, accuracy: 0.000_000_1)
        XCTAssertEqual(justBefore.elapsedSeconds, 7.499, accuracy: 0.000_000_1)
        XCTAssertEqual(justBefore.progress, 0.999_866_666_667, accuracy: 0.000_000_1)
        XCTAssertEqual(justBefore.remainingSeconds, 0.001, accuracy: 0.000_000_1)
        XCTAssertEqual(justBefore.parity, .even)

        let nextBoundary = clock.snapshot(at: Date(timeIntervalSince1970: 22.5))
        XCTAssertEqual(nextBoundary.slotIndex, 3)
        XCTAssertEqual(nextBoundary.slotStart.timeIntervalSince1970, 22.5, accuracy: 0.000_000_1)
        XCTAssertEqual(nextBoundary.elapsedSeconds, 0.0, accuracy: 0.000_000_1)
        XCTAssertEqual(nextBoundary.progress, 0.0, accuracy: 0.000_000_1)
        XCTAssertEqual(nextBoundary.remainingSeconds, 7.5, accuracy: 0.000_000_1)
        XCTAssertEqual(nextBoundary.parity, .odd)
    }

    func testDisplayStateUsesRigPTTAndAutomaticQSOTransmitParity() throws {
        let clock = try XCTUnwrap(RadioLiteDigitalSlotClock(mode: "FT8"))
        let evenQSO = makeAutomaticQSO(txParity: "even")
        let receivingRig = makeRigState(ptt: false)
        let transmittingRig = makeRigState(ptt: true)

        XCTAssertEqual(
            clock.displayState(
                at: Date(timeIntervalSince1970: 45.0),
                rigState: transmittingRig,
                automaticQSO: evenQSO
            ),
            .transmitting,
            "physical PTT readback is authoritative even during an unexpected slot"
        )
        XCTAssertEqual(
            clock.displayState(
                at: Date(timeIntervalSince1970: 30.0),
                rigState: receivingRig,
                automaticQSO: evenQSO
            ),
            .waitingToTransmit,
            "the assigned TX slot is waiting until the server actually keys PTT"
        )
        XCTAssertEqual(
            clock.displayState(
                at: Date(timeIntervalSince1970: 45.0),
                rigState: receivingRig,
                automaticQSO: evenQSO
            ),
            .receiving,
            "the opposite parity is the receive slot"
        )
        XCTAssertEqual(
            clock.displayState(
                at: Date(timeIntervalSince1970: 30.0),
                rigState: receivingRig,
                automaticQSO: nil
            ),
            .receiving,
            "without an active automatic QSO, an unkeyed radio is simply receiving"
        )

        let oddQSO = makeAutomaticQSO(txParity: "odd")
        XCTAssertEqual(
            clock.displayState(
                at: Date(timeIntervalSince1970: 45.0),
                rigState: receivingRig,
                automaticQSO: oddQSO
            ),
            .waitingToTransmit
        )
        XCTAssertEqual(
            clock.displayState(
                at: Date(timeIntervalSince1970: 30.0),
                rigState: receivingRig,
                automaticQSO: oddQSO
            ),
            .receiving
        )
    }

    private func makeRigState(ptt: Bool) -> RadioLiteRigState {
        RadioLiteRigState(
            frequencyHz: 14_074_000,
            mode: "PKTUSB",
            passbandHz: 3_000,
            ptt: ptt
        )
    }

    private func makeAutomaticQSO(txParity: String) -> RadioLiteAutoQSO {
        RadioLiteAutoQSO(
            id: "qso-1",
            radioId: "main",
            queueEntryId: "queue-1",
            targetCallsign: "JA1ABC",
            targetGrid: "PM95",
            myCallsign: "BI1ABC",
            myGrid: "OM89",
            mode: "FT8",
            dialFrequencyHz: 14_074_000,
            audioFrequencyHz: 1_300,
            txParity: txParity,
            phase: "calling",
            outboundMessage: "JA1ABC BI1ABC OM89",
            reportSent: nil,
            reportReceived: nil,
            callAttempts: 0,
            reportAttempts: 0,
            finalAttempts: 0,
            startedAtMs: 30_000,
            endedAtMs: nil,
            lastActivityAtMs: 30_000,
            lastInboundMessage: nil,
            failureReason: nil
        )
    }
}
