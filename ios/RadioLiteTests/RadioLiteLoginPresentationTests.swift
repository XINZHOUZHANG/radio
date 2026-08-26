import XCTest
@testable import RadioLite

final class RadioLiteLoginPresentationTests: XCTestCase {
    func testSetupValidationExplainsEveryRequirementAndAcceptsOneCharacterPassword() {
        let empty = RadioLiteSetupValidation(setupCode: "", username: "", password: "")

        XCTAssertFalse(empty.isValid)
        XCTAssertEqual(empty.setupCodeHint, "初始化码必须是 6 位数字")
        XCTAssertEqual(empty.usernameHint, "用户名须为 3–32 位，可使用字母、数字、点、横线和下划线")
        XCTAssertEqual(empty.passwordHint, "密码仅需非空，可使用任意字符")

        let valid = RadioLiteSetupValidation(setupCode: "123456", username: "admin", password: "1")
        XCTAssertTrue(valid.setupCodeIsValid)
        XCTAssertTrue(valid.usernameIsValid)
        XCTAssertTrue(valid.passwordIsValid)
        XCTAssertTrue(valid.isValid)

        let nonASCII = RadioLiteSetupValidation(setupCode: "１２３４５６", username: "admin", password: "1")
        XCTAssertFalse(nonASCII.setupCodeIsValid, "the server accepts ASCII setup digits only")
    }

    func testSetupValidationUsesTheSameUsernameShapeAsTheServer() {
        XCTAssertTrue(RadioLiteSetupValidation(
            setupCode: "123456",
            username: " Radio.Admin-1 ",
            password: "x"
        ).usernameIsValid)
        XCTAssertFalse(RadioLiteSetupValidation(
            setupCode: "123456",
            username: "ab",
            password: "x"
        ).usernameIsValid)
        XCTAssertFalse(RadioLiteSetupValidation(
            setupCode: "123456",
            username: "radio admin",
            password: "x"
        ).usernameIsValid)
    }

    func testDismissedMediaNoticeIsSuppressedUntilTheMediaProblemIsResolved() {
        var state = RadioLiteNoticeState()
        let key = "media.subscription:osstatus-10875"

        state.present("媒体订阅受限：OSStatus -10875", deduplicationKey: key)
        XCTAssertEqual(state.message, "媒体订阅受限：OSStatus -10875")

        state.dismiss()
        XCTAssertNil(state.message)

        state.present("媒体订阅受限：OSStatus -10875", deduplicationKey: key)
        XCTAssertNil(state.message, "a dismissed duplicate must stay dismissed")

        state.resolve(keysWithPrefix: "media.subscription:")
        state.present("媒体订阅受限：OSStatus -10875", deduplicationKey: key)
        XCTAssertEqual(state.message, "媒体订阅受限：OSStatus -10875")
    }

    func testDifferentMediaFailureCanStillBeReportedAfterDismissingThePreviousOne() {
        var state = RadioLiteNoticeState()
        state.present("媒体错误 A", deduplicationKey: "media.subscription:a")
        state.dismiss()
        state.present("媒体错误 B", deduplicationKey: "media.subscription:b")

        XCTAssertEqual(state.message, "媒体错误 B")
    }
}
