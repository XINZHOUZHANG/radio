import XCTest
@testable import RadioLite

final class RadioLiteFTMessageTests: XCTestCase {
    func testParsesCQAndDirectedMessagesIntoSenderRecipientAndGrid() {
        XCTAssertEqual(
            RadioLiteFTMessage.parse("CQ JA1ABC PM95"),
            RadioLiteFTMessage(sender: "JA1ABC", recipient: "CQ", grid: "PM95")
        )
        XCTAssertEqual(
            RadioLiteFTMessage.parse("CQ DX PA3ABC JO21"),
            RadioLiteFTMessage(sender: "PA3ABC", recipient: "CQ", grid: "JO21")
        )
        XCTAssertEqual(
            RadioLiteFTMessage.parse("BG2TEST HL2ABC -07"),
            RadioLiteFTMessage(sender: "HL2ABC", recipient: "BG2TEST", grid: nil)
        )
    }

    func testDirectedExchangePayloadsAreNeverParsedAsMaidenheadLocators() {
        for payload in ["RR73", "RRR", "73", "R-10", "+05"] {
            XCTAssertNil(
                RadioLiteFTMessage.parse("BG2TEST JA1ABC \(payload)").grid,
                payload
            )
        }
    }

    func testOfflineCountryLookupCoversCommonFTCallsignPrefixes() {
        let expectedCountries = [
            "JA1ABC": "日本",
            "BH4ABC": "中国",
            "PA3ABC": "荷兰",
            "HL2ABC": "韩国",
            "OE1ABC": "奥地利",
            "OH2ABC": "芬兰",
            "VU2ABC": "印度",
            "UB3ABC": "俄罗斯",
            "RD3ABC": "俄罗斯",
            "JQ1ABC": "日本",
            "F1ABC": "法国",
        ]

        for (callsign, expected) in expectedCountries {
            XCTAssertEqual(
                RadioLiteCallsignCountryResolver.offline.country(for: callsign),
                expected,
                callsign
            )
        }
    }

    func testCountryResolverUsesLongestMatchingPrefix() {
        let resolver = RadioLiteCallsignCountryResolver(entries: [
            .init(prefix: "F", country: "broad"),
            .init(prefix: "F1", country: "specific"),
        ])

        XCTAssertEqual(resolver.country(for: "F1ABC"), "specific")
        XCTAssertEqual(resolver.country(for: "F4ABC"), "broad")
    }

    func testOfflineCountryLookupCoversMajorCallsignPrefixFamilies() {
        let expectedCountries = [
            "K1ABC": "美国",
            "W1ABC": "美国",
            "N1ABC": "美国",
            "AA1ABC": "美国",
            "AL7ABC": "美国",
            "VE3ABC": "加拿大",
            "VA2ABC": "加拿大",
            "VY1ABC": "加拿大",
            "G4ABC": "英国",
            "M0ABC": "英国",
            "2E0ABC": "英国",
            "DA1ABC": "德国",
            "DB1ABC": "德国",
            "DC1ABC": "德国",
            "DD1ABC": "德国",
            "DE1ABC": "德国",
            "DF1ABC": "德国",
            "DG1ABC": "德国",
            "DH1ABC": "德国",
            "DI1ABC": "德国",
            "DJ1ABC": "德国",
            "DK1ABC": "德国",
            "DL1ABC": "德国",
            "DM1ABC": "德国",
            "DN1ABC": "德国",
            "DO1ABC": "德国",
            "DP1ABC": "德国",
            "DQ1ABC": "德国",
            "DR1ABC": "德国",
            "VK3ABC": "澳大利亚",
            "I1ABC": "意大利",
            "EA1ABC": "西班牙",
            "PY2ABC": "巴西",
            "LU1ABC": "阿根廷",
            "ZL1ABC": "新西兰",
            "ZS1ABC": "南非",
        ]

        for (callsign, expected) in expectedCountries {
            XCTAssertEqual(
                RadioLiteCallsignCountryResolver.offline.country(for: callsign),
                expected,
                callsign
            )
        }
    }

    func testOfflineCountryLookupCoversCommonEntitiesAcrossEveryRegion() {
        let expectedCountries = [
            // Europe, including the prefixes raised during review.
            "ON4ABC": "比利时",
            "SM5ABC": "瑞典",
            "SP9ABC": "波兰",
            "OK1ABC": "捷克",
            "OM2ABC": "斯洛伐克",
            "S51ABC": "斯洛文尼亚",
            "YO3ABC": "罗马尼亚",
            "HA5ABC": "匈牙利",
            "HB9ABC": "瑞士",
            "LA1ABC": "挪威",
            "OZ2ABC": "丹麦",
            "EI4ABC": "爱尔兰",
            "CT1ABC": "葡萄牙",
            "SV1ABC": "希腊",
            "LZ2ABC": "保加利亚",
            "UR5ABC": "乌克兰",
            "TA2ABC": "土耳其",

            // Asia.
            "YB1ABC": "印度尼西亚",
            "BV2ABC": "中国台湾",
            "VR2ABC": "中国香港",
            "DU1ABC": "菲律宾",
            "HS0ABC": "泰国",
            "9V1ABC": "新加坡",
            "9M2ABC": "马来西亚",
            "A61ABC": "阿联酋",
            "4X1ABC": "以色列",
            "UN7ABC": "哈萨克斯坦",

            // North America and the Caribbean.
            "XE1ABC": "墨西哥",
            "C6ABC": "巴哈马",
            "HI8ABC": "多米尼加共和国",
            "KP4ABC": "波多黎各",
            "KL7ABC": "美国阿拉斯加",
            "KH6ABC": "美国夏威夷",

            // South America.
            "CE3ABC": "智利",
            "HK3ABC": "哥伦比亚",
            "YV5ABC": "委内瑞拉",
            "OA4ABC": "秘鲁",
            "CX2ABC": "乌拉圭",
            "ZP5ABC": "巴拉圭",

            // Oceania.
            "P29ABC": "巴布亚新几内亚",
            "3D2ABC": "斐济",
            "A35ABC": "汤加",
            "V63ABC": "密克罗尼西亚联邦",
            "T88ABC": "帕劳",

            // Africa.
            "SU1ABC": "埃及",
            "CN8ABC": "摩洛哥",
            "5Z4ABC": "肯尼亚",
            "5N1ABC": "尼日利亚",
            "V51ABC": "纳米比亚",
            "A22ABC": "博茨瓦纳",
            "3B8ABC": "毛里求斯",
        ]

        for (callsign, expected) in expectedCountries {
            XCTAssertEqual(
                RadioLiteCallsignCountryResolver.offline.country(for: callsign),
                expected,
                callsign
            )
        }
    }

    func testUnknownCountryRemainsExplicitlyRepresentableByTheUI() {
        XCTAssertNil(
            RadioLiteCallsignCountryResolver.offline.country(for: "QZ0ZZZ")
        )
        XCTAssertEqual(
            RadioLiteCallsignCountryResolver.offline.countryLabel(for: "QZ0ZZZ"),
            "未知地区"
        )
        XCTAssertEqual(
            RadioLiteCallsignCountryResolver.offline.country(for: "1A1ZZZ"),
            "马耳他主权骑士团"
        )
    }

    func testPortableCallsignLookupUsesTheMainCallsignSegment() {
        XCTAssertEqual(
            RadioLiteCallsignCountryResolver.offline.country(for: "JA1ABC/P"),
            "日本"
        )
        XCTAssertEqual(
            RadioLiteCallsignCountryResolver.offline.country(for: "F/JA1ABC"),
            "日本"
        )
        XCTAssertEqual(
            RadioLiteCallsignCountryResolver.offline.country(for: "ON4ABC/M"),
            "比利时"
        )
        XCTAssertEqual(
            RadioLiteCallsignCountryResolver.offline.country(for: "YB1ABC/QRP"),
            "印度尼西亚"
        )
    }

    func testMessageEmphasisPrioritizesMessagesAddressedToThisStation() {
        XCTAssertEqual(
            RadioLiteFTMessage.parse("CQ JA1ABC PM95").emphasis(myCallsign: "BG2TEST"),
            .cq
        )
        XCTAssertEqual(
            RadioLiteFTMessage.parse("BG2TEST JA1ABC -10").emphasis(myCallsign: "bg2test"),
            .addressedToMe
        )
        XCTAssertEqual(
            RadioLiteFTMessage.parse("PA3ABC JA1ABC -10").emphasis(myCallsign: "BG2TEST"),
            .normal
        )
    }

    func testMaidenheadDistanceReturnsGreatCircleKilometers() throws {
        XCTAssertEqual(RadioLiteMaidenheadDistance.kilometers(from: "PM95", to: "PM95"), 0)

        let beijingToTokyo = try XCTUnwrap(
            RadioLiteMaidenheadDistance.kilometers(from: "OM89", to: "PM95")
        )
        XCTAssertTrue((1_950...2_050).contains(beijingToTokyo), "got \(beijingToTokyo) km")
        XCTAssertNil(RadioLiteMaidenheadDistance.kilometers(from: "not-a-grid", to: "PM95"))
    }
}
