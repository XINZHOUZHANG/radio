import Foundation

enum RadioLiteFTMessageEmphasis: Equatable, Sendable {
    case normal
    case cq
    case addressedToMe
}

struct RadioLiteFTMessage: Equatable, Sendable {
    let sender: String?
    let recipient: String?
    let grid: String?

    static func parse(_ rawValue: String) -> Self {
        let tokens = rawValue
            .uppercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { normalizeToken(String($0)) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            return RadioLiteFTMessage(sender: nil, recipient: nil, grid: nil)
        }

        if tokens[0] == "CQ" {
            let senderIndex = tokens.indices.dropFirst().first {
                looksLikeCallsign(tokens[$0])
            }
            let sender = senderIndex.map { tokens[$0] }
            let grid = senderIndex.flatMap { index in
                tokens.indices.dropFirst(index + 1).lazy
                    .map { tokens[$0] }
                    .first(where: RadioLiteMaidenheadDistance.isLocator)
            }
            return RadioLiteFTMessage(sender: sender, recipient: "CQ", grid: grid)
        }

        let recipient = tokens.indices.contains(0) && looksLikeCallsign(tokens[0])
            ? tokens[0]
            : nil
        let sender = tokens.indices.contains(1) && looksLikeCallsign(tokens[1])
            ? tokens[1]
            : nil
        let grid = tokens.dropFirst(2).first {
            !isDirectedExchangePayload($0)
                && RadioLiteMaidenheadDistance.isLocator($0)
        }
        return RadioLiteFTMessage(sender: sender, recipient: recipient, grid: grid)
    }

    func emphasis(myCallsign: String?) -> RadioLiteFTMessageEmphasis {
        let normalizedCallsign = myCallsign.map(Self.normalizeToken)
        if let normalizedCallsign, !normalizedCallsign.isEmpty,
           recipient == normalizedCallsign {
            return .addressedToMe
        }
        return recipient == "CQ" ? .cq : .normal
    }

    fileprivate static func normalizeToken(_ value: String) -> String {
        value
            .uppercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>[]{}(),"))
    }

    private static func looksLikeCallsign(_ value: String) -> Bool {
        guard (3...12).contains(value.count),
              !RadioLiteMaidenheadDistance.isLocator(value) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return value.contains(where: \.isLetter) && value.contains(where: \.isNumber)
    }

    private static func isDirectedExchangePayload(_ value: String) -> Bool {
        if value == "RRR" || value == "RR73" || value == "73" { return true }
        let report = value.hasPrefix("R") ? value.dropFirst() : value[...]
        guard report.count == 3,
              report.first == "+" || report.first == "-" else { return false }
        return report.dropFirst().allSatisfy(\.isNumber)
    }
}

enum RadioLiteFTDecodeMessageFormatter {
    static func text(_ rawValue: String) -> String {
        let message = RadioLiteFTMessage.parse(rawValue)
        guard let sender = message.sender,
              let flag = RadioLiteCallsignCountryResolver.offline.flag(for: sender) else {
            return rawValue
        }
        let rawTokens = rawValue.split(whereSeparator: { $0.isWhitespace })
        let normalizedTokens = rawTokens.map {
            RadioLiteFTMessage.normalizeToken(String($0))
        }
        let senderIndex: Int?
        if normalizedTokens.first == "CQ" {
            senderIndex = normalizedTokens.indices.dropFirst().first {
                normalizedTokens[$0] == sender
            }
        } else if normalizedTokens.indices.contains(1), normalizedTokens[1] == sender {
            senderIndex = 1
        } else {
            senderIndex = nil
        }
        guard let senderIndex else { return rawValue }

        let insertionOffset = rawValue.distance(
            from: rawValue.startIndex,
            to: rawTokens[senderIndex].endIndex
        )
        var result = rawValue
        let insertionIndex = result.index(result.startIndex, offsetBy: insertionOffset)
        result.insert(contentsOf: " \(flag)", at: insertionIndex)
        return result
    }
}

struct RadioLiteCallsignLocation: Equatable, Sendable {
    let country: String
    let region: String?
    let flag: String?
}

enum RadioLiteFTDecodeMetadataFormatter {
    static func text(
        sender: String?,
        distanceKilometers: Int?
    ) -> String? {
        var components: [String] = []
        if let sender {
            if let location = RadioLiteCallsignCountryResolver.offline.location(for: sender) {
                components.append(location.country)
                if let region = location.region,
                   region != location.country {
                    components.append(region)
                }
            } else {
                components.append("未知地区")
            }
        }
        if let distanceKilometers {
            components.append("\(distanceKilometers) km")
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }
}

struct RadioLiteCallsignCountryResolver: Sendable {
    struct Entry: Equatable, Sendable {
        let prefix: String
        let country: String
        let region: String?

        init(prefix: String, country: String, region: String? = nil) {
            self.prefix = prefix
            self.country = country
            self.region = region
        }
    }

    static let offline: RadioLiteCallsignCountryResolver = {
        var catalog: [Entry] = []
        catalog.append(contentsOf:
        entries(country: "日本", prefixes: [
            "JA", "JE", "JF", "JG", "JH", "JI", "JJ", "JK", "JL", "JM",
            "JN", "JO", "JP", "JQ", "JR", "JS", "7J", "8J",
        ])
        + entries(country: "中国", prefixes: ["B"])
        + entries(country: "荷兰", prefixes: [
            "PA", "PB", "PC", "PD", "PE", "PF", "PG", "PH", "PI",
        ])
        + entries(country: "韩国", prefixes: ["HL", "DS", "DT"])
        + entries(country: "奥地利", prefixes: ["OE"])
        + entries(country: "芬兰", prefixes: ["OF", "OG", "OH", "OI"])
        + entries(country: "印度", prefixes: ["VU"])
        + entries(country: "俄罗斯", prefixes: [
            "R", "UA", "UB", "UC", "UD", "UE", "UF", "UG", "UH", "UI",
        ])
        + entries(country: "法国", prefixes: ["F"])
        + entries(country: "美国", prefixes: [
            "K", "W", "N", "AA", "AB", "AC", "AD", "AE", "AF", "AG",
            "AH", "AI", "AJ", "AK", "AL",
        ])
        + entries(country: "加拿大", prefixes: ["VA", "VE", "VY"])
        + entries(country: "英国", prefixes: ["G", "M", "2E"])
        + entries(country: "德国", prefixes: [
            "DA", "DB", "DC", "DD", "DE", "DF", "DG", "DH", "DI", "DJ",
            "DK", "DL", "DM", "DN", "DO", "DP", "DQ", "DR",
        ])
        + entries(country: "澳大利亚", prefixes: ["VK"])
        + entries(country: "意大利", prefixes: ["I"])
        + entries(country: "西班牙", prefixes: ["EA"])
        + entries(country: "巴西", prefixes: ["PY"])
        + entries(country: "阿根廷", prefixes: ["LU"])
        + entries(country: "新西兰", prefixes: ["ZL"])
        + entries(country: "南非", prefixes: ["ZS"])
        )
        // Europe. These are compact allocation families rather than a network
        // lookup, so the decode list stays useful on slow or offline links.
        catalog.append(contentsOf:
        entries(country: "比利时", prefixes: ["ON", "OO", "OP", "OQ", "OR", "OS", "OT"])
        + entries(country: "瑞典", prefixes: ["SA", "SB", "SC", "SD", "SE", "SF", "SG", "SH", "SI", "SJ", "SK", "SL", "SM", "7S", "8S"])
        + entries(country: "波兰", prefixes: ["SP", "SQ", "SN", "SO", "HF", "3Z"])
        + entries(country: "捷克", prefixes: ["OK", "OL"])
        + entries(country: "斯洛伐克", prefixes: ["OM"])
        + entries(country: "斯洛文尼亚", prefixes: ["S5"])
        + entries(country: "罗马尼亚", prefixes: ["YO", "YP", "YQ", "YR"])
        + entries(country: "匈牙利", prefixes: ["HA", "HG"])
        + entries(country: "列支敦士登", prefixes: ["HB0"])
        + entries(country: "瑞士", prefixes: ["HB"])
        + entries(country: "挪威", prefixes: ["LA", "LB", "LC", "LD", "LE", "LF", "LG", "LH", "LI", "LJ", "LK", "LL", "LM", "LN"])
        + entries(country: "丹麦", prefixes: ["OZ", "OU", "OV", "OW", "5P", "5Q"])
        + entries(country: "爱尔兰", prefixes: ["EI", "EJ"])
        + entries(country: "葡萄牙", prefixes: ["CT", "CR", "CS", "CU"])
        + entries(country: "希腊", prefixes: ["SV", "SX", "SY", "SZ", "J4"])
        + entries(country: "保加利亚", prefixes: ["LZ"])
        + entries(country: "乌克兰", prefixes: ["EM", "EN", "EO", "UR", "US", "UT", "UU", "UV", "UW", "UX", "UY", "UZ"])
        )
        catalog.append(contentsOf:
        entries(country: "土耳其", prefixes: ["TA", "TB", "TC", "YM"])
        + entries(country: "克罗地亚", prefixes: ["9A"])
        + entries(country: "塞尔维亚", prefixes: ["YT", "YU"])
        + entries(country: "波黑", prefixes: ["E7"])
        + entries(country: "北马其顿", prefixes: ["Z3"])
        + entries(country: "立陶宛", prefixes: ["LY"])
        + entries(country: "拉脱维亚", prefixes: ["YL"])
        + entries(country: "爱沙尼亚", prefixes: ["ES"])
        + entries(country: "冰岛", prefixes: ["TF"])
        + entries(country: "白俄罗斯", prefixes: ["EU", "EV", "EW"])
        + entries(country: "摩尔多瓦", prefixes: ["ER"])
        + entries(country: "卢森堡", prefixes: ["LX"])
        + entries(country: "摩纳哥", prefixes: ["3A"])
        + entries(country: "安道尔", prefixes: ["C3"])
        + entries(country: "马耳他", prefixes: ["9H"])
        + entries(country: "马耳他主权骑士团", prefixes: ["1A"])
        + entries(country: "塞浦路斯", prefixes: ["5B", "C4", "H2", "P3"])
        )
        // Asia and the Middle East.
        catalog.append(contentsOf:
        entries(country: "印度尼西亚", prefixes: ["YB", "YC", "YD", "YE", "YF", "YG", "YH", "7A", "7B", "7C", "7D", "7E", "7F", "7G", "7H", "7I", "8A", "8B", "8C", "8D", "8E", "8F", "8G", "8H", "8I"])
        + entries(country: "中国", region: "台湾", prefixes: ["BM", "BN", "BO", "BP", "BQ", "BU", "BV", "BW", "BX"])
        + entries(country: "中国", region: "香港", prefixes: ["VR2"])
        + entries(country: "中国", region: "澳门", prefixes: ["XX9"])
        + entries(country: "菲律宾", prefixes: ["DU", "DV", "DW", "DX", "DY", "DZ", "4D", "4E", "4F", "4G", "4H", "4I"])
        + entries(country: "泰国", prefixes: ["HS", "E2"])
        + entries(country: "新加坡", prefixes: ["9V", "S6"])
        + entries(country: "马来西亚", prefixes: ["9M"])
        + entries(country: "阿联酋", prefixes: ["A6"])
        + entries(country: "以色列", prefixes: ["4X", "4Z"])
        + entries(country: "哈萨克斯坦", prefixes: ["UN", "UO", "UP", "UQ"])
        + entries(country: "沙特阿拉伯", prefixes: ["HZ", "7Z", "8Z"])
        + entries(country: "卡塔尔", prefixes: ["A7"])
        + entries(country: "科威特", prefixes: ["9K"])
        + entries(country: "阿曼", prefixes: ["A4"])
        + entries(country: "巴林", prefixes: ["A9"])
        + entries(country: "孟加拉国", prefixes: ["S2"])
        )
        catalog.append(contentsOf:
        entries(country: "斯里兰卡", prefixes: ["4S"])
        + entries(country: "巴基斯坦", prefixes: ["AP", "AQ", "AR", "AS"])
        + entries(country: "蒙古", prefixes: ["JT", "JU", "JV"])
        + entries(country: "越南", prefixes: ["3W", "XV"])
        + entries(country: "柬埔寨", prefixes: ["XU"])
        + entries(country: "老挝", prefixes: ["XW"])
        + entries(country: "缅甸", prefixes: ["XZ"])
        + entries(country: "尼泊尔", prefixes: ["9N"])
        + entries(country: "伊朗", prefixes: ["EP", "EQ"])
        + entries(country: "伊拉克", prefixes: ["YI"])
        + entries(country: "阿富汗", prefixes: ["YA", "T6"])
        + entries(country: "吉尔吉斯斯坦", prefixes: ["EX"])
        + entries(country: "乌兹别克斯坦", prefixes: ["UK", "UL", "UM"])
        + entries(country: "塔吉克斯坦", prefixes: ["EY"])
        + entries(country: "土库曼斯坦", prefixes: ["EZ"])
        )
        // Americas and the Caribbean.
        catalog.append(contentsOf:
        entries(country: "墨西哥", prefixes: ["XA", "XB", "XC", "XD", "XE", "XF", "XG", "XH", "XI", "4A", "4B", "4C", "6D", "6E", "6F", "6G", "6H", "6I", "6J"])
        + entries(country: "巴哈马", prefixes: ["C6"])
        + entries(country: "多米尼加共和国", prefixes: ["HI"])
        + entries(country: "波多黎各", prefixes: ["KP3", "KP4", "NP3", "NP4", "WP3", "WP4"])
        + entries(country: "美国阿拉斯加", prefixes: ["KL7"])
        + entries(country: "美国夏威夷", prefixes: ["KH6", "KH7", "NH6", "WH6", "AH6"])
        + entries(country: "古巴", prefixes: ["CM", "CO", "T4"])
        + entries(country: "哥斯达黎加", prefixes: ["TI", "TE"])
        + entries(country: "巴拿马", prefixes: ["HP", "HO", "3E", "3F"])
        + entries(country: "牙买加", prefixes: ["6Y"])
        + entries(country: "特立尼达和多巴哥", prefixes: ["9Y", "9Z"])
        + entries(country: "巴巴多斯", prefixes: ["8P"])
        )
        catalog.append(contentsOf:
        entries(country: "智利", prefixes: ["CA", "CB", "CC", "CD", "CE", "XQ", "XR", "3G"])
        + entries(country: "哥伦比亚", prefixes: ["HJ", "HK", "5J", "5K"])
        + entries(country: "委内瑞拉", prefixes: ["YV", "YW", "YX", "YY", "4M"])
        + entries(country: "秘鲁", prefixes: ["OA", "OB", "OC", "4T"])
        + entries(country: "乌拉圭", prefixes: ["CV", "CW", "CX"])
        + entries(country: "巴拉圭", prefixes: ["ZP"])
        + entries(country: "厄瓜多尔", prefixes: ["HC", "HD"])
        + entries(country: "玻利维亚", prefixes: ["CP"])
        + entries(country: "圭亚那", prefixes: ["8R"])
        + entries(country: "苏里南", prefixes: ["PZ"])
        )
        // Oceania and Africa.
        catalog.append(contentsOf:
        entries(country: "巴布亚新几内亚", prefixes: ["P2"])
        + entries(country: "斐济", prefixes: ["3D2"])
        + entries(country: "汤加", prefixes: ["A3"])
        + entries(country: "密克罗尼西亚联邦", prefixes: ["V6"])
        + entries(country: "帕劳", prefixes: ["T8"])
        + entries(country: "萨摩亚", prefixes: ["5W"])
        + entries(country: "瓦努阿图", prefixes: ["YJ"])
        + entries(country: "所罗门群岛", prefixes: ["H4"])
        + entries(country: "埃及", prefixes: ["SU"])
        + entries(country: "摩洛哥", prefixes: ["CN", "5C", "5D", "5E", "5F", "5G"])
        + entries(country: "肯尼亚", prefixes: ["5Z"])
        + entries(country: "尼日利亚", prefixes: ["5N", "5O"])
        + entries(country: "纳米比亚", prefixes: ["V5"])
        + entries(country: "博茨瓦纳", prefixes: ["A2"])
        )
        catalog.append(contentsOf:
        entries(country: "毛里求斯", prefixes: ["3B8"])
        + entries(country: "阿尔及利亚", prefixes: ["7X"])
        + entries(country: "突尼斯", prefixes: ["3V", "TS"])
        + entries(country: "埃塞俄比亚", prefixes: ["ET", "9E"])
        + entries(country: "坦桑尼亚", prefixes: ["5H", "5I"])
        + entries(country: "加纳", prefixes: ["9G"])
        + entries(country: "塞内加尔", prefixes: ["6V", "6W"])
        + entries(country: "乌干达", prefixes: ["5X"])
        + entries(country: "赞比亚", prefixes: ["9J"])
        + entries(country: "津巴布韦", prefixes: ["Z2"])
        + entries(country: "莫桑比克", prefixes: ["C9"])
        + entries(country: "安哥拉", prefixes: ["D2", "D3"])
        + entries(country: "马达加斯加", prefixes: ["5R", "5S"])
        )
        return RadioLiteCallsignCountryResolver(entries: catalog)
    }()

    private let entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
            .map {
                Entry(
                    prefix: $0.prefix.uppercased(),
                    country: $0.country,
                    region: $0.region
                )
            }
            .sorted {
                if $0.prefix.count == $1.prefix.count { return $0.prefix < $1.prefix }
                return $0.prefix.count > $1.prefix.count
            }
    }

    func location(for callsign: String) -> RadioLiteCallsignLocation? {
        let normalized = callsign
            .uppercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        let segments = normalized
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        let portableDesignators: Set<String> = ["P", "M", "MM", "AM", "QRP"]
        let meaningfulSegments = segments.enumerated().filter {
            !portableDesignators.contains($0.element)
        }
        guard let main = meaningfulSegments
            .filter({ candidate in
                candidate.element.contains(where: \.isLetter)
                    && candidate.element.contains(where: \.isNumber)
            })
            .max(by: { left, right in
                if left.element.count == right.element.count {
                    return left.offset > right.offset
                }
                return left.element.count < right.element.count
            }),
              let mainLocation = matchedLocation(for: main.element) else { return nil }

        var explicitLocations: [RadioLiteCallsignLocation] = []
        for candidate in meaningfulSegments where candidate.offset != main.offset {
            if candidate.element.allSatisfy(\.isNumber) { continue }
            guard let location = matchedOperatingLocation(for: candidate.element) else {
                return nil
            }
            explicitLocations.append(location)
        }
        guard let explicitLocation = explicitLocations.first else {
            return mainLocation
        }
        guard explicitLocations.dropFirst().allSatisfy({
            $0.country == explicitLocation.country
                && $0.region == explicitLocation.region
                && $0.flag == explicitLocation.flag
        }) else { return nil }
        return explicitLocation
    }

    func country(for callsign: String) -> String? {
        location(for: callsign)?.country
    }

    func flag(for callsign: String) -> String? {
        location(for: callsign)?.flag
    }

    func countryLabel(for callsign: String) -> String {
        country(for: callsign) ?? "未知地区"
    }

    private static let flagRegionCodes: [String: String] = [
        "阿尔及利亚": "DZ",
        "阿富汗": "AF",
        "阿根廷": "AR",
        "阿联酋": "AE",
        "阿曼": "OM",
        "埃及": "EG",
        "埃塞俄比亚": "ET",
        "爱尔兰": "IE",
        "爱沙尼亚": "EE",
        "安道尔": "AD",
        "安哥拉": "AO",
        "奥地利": "AT",
        "澳大利亚": "AU",
        "巴巴多斯": "BB",
        "巴布亚新几内亚": "PG",
        "巴哈马": "BS",
        "巴基斯坦": "PK",
        "巴拉圭": "PY",
        "巴林": "BH",
        "巴拿马": "PA",
        "巴西": "BR",
        "白俄罗斯": "BY",
        "保加利亚": "BG",
        "北马其顿": "MK",
        "比利时": "BE",
        "冰岛": "IS",
        "波多黎各": "PR",
        "波黑": "BA",
        "波兰": "PL",
        "玻利维亚": "BO",
        "博茨瓦纳": "BW",
        "丹麦": "DK",
        "德国": "DE",
        "多米尼加共和国": "DO",
        "俄罗斯": "RU",
        "厄瓜多尔": "EC",
        "法国": "FR",
        "菲律宾": "PH",
        "斐济": "FJ",
        "芬兰": "FI",
        "哥伦比亚": "CO",
        "哥斯达黎加": "CR",
        "古巴": "CU",
        "圭亚那": "GY",
        "哈萨克斯坦": "KZ",
        "韩国": "KR",
        "荷兰": "NL",
        "吉尔吉斯斯坦": "KG",
        "加拿大": "CA",
        "加纳": "GH",
        "柬埔寨": "KH",
        "捷克": "CZ",
        "津巴布韦": "ZW",
        "卡塔尔": "QA",
        "科威特": "KW",
        "克罗地亚": "HR",
        "肯尼亚": "KE",
        "拉脱维亚": "LV",
        "老挝": "LA",
        "立陶宛": "LT",
        "列支敦士登": "LI",
        "卢森堡": "LU",
        "罗马尼亚": "RO",
        "马达加斯加": "MG",
        "马耳他": "MT",
        "马来西亚": "MY",
        "毛里求斯": "MU",
        "美国": "US",
        "美国阿拉斯加": "US",
        "美国夏威夷": "US",
        "蒙古": "MN",
        "孟加拉国": "BD",
        "秘鲁": "PE",
        "密克罗尼西亚联邦": "FM",
        "缅甸": "MM",
        "摩尔多瓦": "MD",
        "摩洛哥": "MA",
        "摩纳哥": "MC",
        "莫桑比克": "MZ",
        "墨西哥": "MX",
        "纳米比亚": "NA",
        "南非": "ZA",
        "尼泊尔": "NP",
        "尼日利亚": "NG",
        "挪威": "NO",
        "帕劳": "PW",
        "葡萄牙": "PT",
        "日本": "JP",
        "瑞典": "SE",
        "瑞士": "CH",
        "萨摩亚": "WS",
        "塞尔维亚": "RS",
        "塞内加尔": "SN",
        "塞浦路斯": "CY",
        "沙特阿拉伯": "SA",
        "斯里兰卡": "LK",
        "斯洛伐克": "SK",
        "斯洛文尼亚": "SI",
        "苏里南": "SR",
        "所罗门群岛": "SB",
        "塔吉克斯坦": "TJ",
        "泰国": "TH",
        "坦桑尼亚": "TZ",
        "汤加": "TO",
        "特立尼达和多巴哥": "TT",
        "突尼斯": "TN",
        "土耳其": "TR",
        "土库曼斯坦": "TM",
        "瓦努阿图": "VU",
        "委内瑞拉": "VE",
        "乌干达": "UG",
        "乌克兰": "UA",
        "乌拉圭": "UY",
        "乌兹别克斯坦": "UZ",
        "西班牙": "ES",
        "希腊": "GR",
        "新加坡": "SG",
        "新西兰": "NZ",
        "匈牙利": "HU",
        "牙买加": "JM",
        "伊拉克": "IQ",
        "伊朗": "IR",
        "以色列": "IL",
        "意大利": "IT",
        "印度": "IN",
        "印度尼西亚": "ID",
        "英国": "GB",
        "越南": "VN",
        "赞比亚": "ZM",
        "智利": "CL",
        "中国": "CN",
        "中国/澳门": "MO",
        "中国/台湾": "TW",
        "中国/香港": "HK",
    ]

    private static func entries(
        country: String,
        region: String? = nil,
        prefixes: [String]
    ) -> [Entry] {
        prefixes.map { Entry(prefix: $0, country: country, region: region) }
    }

    private func matchedLocation(for candidate: String) -> RadioLiteCallsignLocation? {
        guard let entry = entries.first(where: { candidate.hasPrefix($0.prefix) }) else {
            return nil
        }
        return location(for: candidate, entry: entry)
    }

    private func matchedOperatingLocation(
        for candidate: String
    ) -> RadioLiteCallsignLocation? {
        guard let entry = entries.first(where: { candidate.hasPrefix($0.prefix) }) else {
            return nil
        }
        let suffix = candidate.dropFirst(entry.prefix.count)
        guard suffix.isEmpty || suffix.allSatisfy(\.isNumber) else { return nil }
        return location(for: candidate, entry: entry)
    }

    private func location(
        for candidate: String,
        entry: Entry
    ) -> RadioLiteCallsignLocation {
        let region = entry.region
            ?? (entry.country == "中国"
                ? RadioLiteChineseCallsignRegion.region(for: candidate)
                : nil)
        let regionCode = Self.flagRegionCodes["\(entry.country)/\(region ?? "")"]
            ?? Self.flagRegionCodes[entry.country]
        return RadioLiteCallsignLocation(
            country: entry.country,
            region: region,
            flag: RadioLiteUnicodeFlag.emoji(forRegionCode: regionCode)
        )
    }
}

private enum RadioLiteUnicodeFlag {
    static func emoji(forRegionCode regionCode: String?) -> String? {
        guard let normalized = regionCode?.uppercased(),
              normalized.unicodeScalars.count == 2,
              normalized.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else {
            return nil
        }
        var flag = ""
        for scalar in normalized.unicodeScalars {
            guard let indicator = UnicodeScalar(127_397 + scalar.value) else { return nil }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }
}

private enum RadioLiteChineseCallsignRegion {
    private static let mainlandStationTypeLetters: Set<Character> = [
        "A", "D", "G", "H", "I", "J",
    ]

    static func region(for callsign: String) -> String? {
        let characters = Array(callsign.uppercased())
        guard characters.count >= 4,
              characters[0] == "B",
              mainlandStationTypeLetters.contains(characters[1]),
              let district = characters[2].wholeNumberValue else { return nil }
        let suffixInitial = characters[3]
        let allocations: [(ClosedRange<Character>, String)]
        switch district {
        case 1:
            allocations = [("A"..."X", "北京")]
        case 2:
            allocations = [
                ("A"..."H", "黑龙江"),
                ("I"..."P", "吉林"),
                ("Q"..."X", "辽宁"),
            ]
        case 3:
            allocations = [
                ("A"..."F", "天津"),
                ("G"..."L", "内蒙古"),
                ("M"..."R", "河北"),
                ("S"..."X", "山西"),
            ]
        case 4:
            allocations = [
                ("A"..."H", "上海"),
                ("I"..."P", "山东"),
                ("Q"..."X", "江苏"),
            ]
        case 5:
            allocations = [
                ("A"..."H", "浙江"),
                ("I"..."P", "江西"),
                ("Q"..."X", "福建"),
            ]
        case 6:
            allocations = [
                ("A"..."H", "安徽"),
                ("I"..."P", "河南"),
                ("Q"..."X", "湖北"),
            ]
        case 7:
            allocations = [
                ("A"..."H", "湖南"),
                ("I"..."P", "广东"),
                ("Q"..."X", "广西"),
                ("Y"..."Z", "海南"),
            ]
        case 8:
            allocations = [
                ("A"..."F", "四川"),
                ("G"..."L", "重庆"),
                ("M"..."R", "贵州"),
                ("S"..."X", "云南"),
            ]
        case 9:
            allocations = [
                ("A"..."F", "陕西"),
                ("G"..."L", "甘肃"),
                ("M"..."R", "宁夏"),
                ("S"..."X", "青海"),
            ]
        case 0:
            allocations = [
                ("A"..."F", "新疆"),
                ("G"..."L", "西藏"),
            ]
        default:
            return nil
        }
        return allocations.first { $0.0.contains(suffixInitial) }?.1
    }
}

enum RadioLiteMaidenheadDistance {
    static func kilometers(from origin: String?, to destination: String?) -> Int? {
        guard let origin, let destination,
              let lhs = coordinate(for: origin),
              let rhs = coordinate(for: destination) else { return nil }
        let latitude1 = lhs.latitude * .pi / 180
        let latitude2 = rhs.latitude * .pi / 180
        let latitudeDelta = (rhs.latitude - lhs.latitude) * .pi / 180
        let longitudeDelta = (rhs.longitude - lhs.longitude) * .pi / 180
        let haversine = pow(sin(latitudeDelta / 2), 2)
            + cos(latitude1) * cos(latitude2) * pow(sin(longitudeDelta / 2), 2)
        let arc = 2 * atan2(sqrt(haversine), sqrt(max(0, 1 - haversine)))
        return Int((6_371.0088 * arc).rounded())
    }

    static func isLocator(_ value: String) -> Bool {
        coordinate(for: value) != nil
    }

    private static func coordinate(
        for locator: String
    ) -> (latitude: Double, longitude: Double)? {
        let characters = Array(locator.uppercased())
        guard characters.count == 4 || characters.count == 6,
              let fieldLongitude = letterIndex(characters[0], upperBound: "R"),
              let fieldLatitude = letterIndex(characters[1], upperBound: "R"),
              let squareLongitude = characters[2].wholeNumberValue,
              let squareLatitude = characters[3].wholeNumberValue else { return nil }

        var longitude = -180 + Double(fieldLongitude * 20 + squareLongitude * 2)
        var latitude = -90 + Double(fieldLatitude * 10 + squareLatitude)
        if characters.count == 6 {
            guard let subLongitude = letterIndex(characters[4], upperBound: "X"),
                  let subLatitude = letterIndex(characters[5], upperBound: "X") else { return nil }
            longitude += Double(subLongitude) / 12 + 1.0 / 24
            latitude += Double(subLatitude) / 24 + 1.0 / 48
        } else {
            longitude += 1
            latitude += 0.5
        }
        return (latitude, longitude)
    }

    private static func letterIndex(_ character: Character, upperBound: Character) -> Int? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1,
              let upperScalar = upperBound.unicodeScalars.first,
              scalar.value >= 65,
              scalar.value <= upperScalar.value else { return nil }
        return Int(scalar.value - 65)
    }
}
