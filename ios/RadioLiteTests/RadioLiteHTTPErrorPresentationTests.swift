import XCTest
@testable import RadioLite

final class RadioLiteHTTPErrorPresentationTests: XCTestCase {
    func testPasswordRejectionExplainsTheCurrentPolicyAndServerUpgrade() {
        let error = RadioLiteHTTPError.http(
            status: 400,
            code: "invalid_request",
            message: "password must contain at least 12 characters"
        )

        XCTAssertEqual(
            error.errorDescription,
            "密码被服务器拒绝。新版 Radio Lite 仅要求密码非空，不限制位数或复杂度；请升级服务端后重试。服务器信息：password must contain at least 12 characters"
        )
    }

    func testExpiredSetupCodeHasAnActionableChineseMessage() {
        let error = RadioLiteHTTPError.http(
            status: 410,
            code: "invalid_or_expired_code",
            message: "code is invalid or expired"
        )

        XCTAssertEqual(
            error.errorDescription,
            "6 位验证码无效或已过期，请在服务器终端重新生成后再试"
        )
    }

    func testKnownAuthenticationFailuresAreLocalized() {
        XCTAssertEqual(
            RadioLiteHTTPError.http(
                status: 401,
                code: "invalid_login",
                message: "invalid username or password"
            ).errorDescription,
            "用户名或密码不正确"
        )
        XCTAssertEqual(
            RadioLiteHTTPError.http(
                status: 409,
                code: "already_initialized",
                message: "server is already initialized"
            ).errorDescription,
            "服务器已经完成初始化，请返回账户登录"
        )
    }

    func testUnknownServerMessageIsPreserved() {
        XCTAssertEqual(
            RadioLiteHTTPError.http(
                status: 503,
                code: "custom_failure",
                message: "radio backend unavailable"
            ).errorDescription,
            "radio backend unavailable"
        )
    }
}
