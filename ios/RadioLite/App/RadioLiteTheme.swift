import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >>  8) & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255,
                  opacity: 1)
    }
}

/// 全 App 唯一的视觉常量来源。新写的 UI 一律引用这里，不要再裸写十六进制。
enum TX {

    // MARK: 底色
    static let bg      = Color(hex: 0x090E13)   // 页面底
    static let card    = Color(hex: 0x10171D)   // 卡片
    static let raised  = Color(hex: 0x161E25)   // 卡片上的控件底
    static let stroke  = Color.white.opacity(0.07)
    static let divider = Color.white.opacity(0.055)

    // MARK: 三个强调色，不允许有第四个
    static let teal  = Color(hex: 0x29D1B7)   // 品牌 / 可操作 / CQ
    static let amber = Color(hex: 0xFFAD2E)   // 与我有关、需要注意、对方给我们的报告
    static let txRed = Color(hex: 0xFF453A)   // 只用于发射（TX 行、PTT）

    // MARK: 文字阶梯（括号内为在 bg 上的对比度，已验算）
    static let text1     = Color.white.opacity(0.92)   // 16.3:1  主文字
    static let text2     = Color.white.opacity(0.66)   //  8.6:1  次文字
    static let text3     = Color.white.opacity(0.46)   //  4.6:1  弱文字，这是下限
    static let textMuted = Color.white.opacity(0.34)   //  3.0:1  仅「已通联」刻意弱化

    // MARK: 尺寸
    static let rowH: CGFloat        = 44   // 解码行 / 日志行标准档
    static let rowHCompact: CGFloat = 36   // 紧凑档
    static let hitMin: CGFloat      = 44   // 触控目标下限
    static let pagePad: CGFloat     = 12
    static let cardRadius: CGFloat  = 13
    static let chipRadius: CGFloat  = 9

    // MARK: 字体
    /// 所有数字、呼号、频率、网格、报文一律等宽 + tabular，否则列对不齐没法竖着扫。
    static func data(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: 瀑布图色标（7 段，起点必须贴近画布背景）
    static let waterfallStops: [(Double, Color)] = [
        (0.00, Color(hex: 0x0A1016)),
        (0.30, Color(hex: 0x0F212A)),
        (0.50, Color(hex: 0x17454B)),
        (0.68, Color(hex: 0x22887E)),
        (0.82, Color(hex: 0x29D1B7)),
        (0.92, Color(hex: 0xFFD98A)),
        (1.00, Color(hex: 0xFFFFFF)),
    ]
}

/// 一条解码消息与本站的关系，决定它长什么样。
enum DecodeKind {
    case toMe      // 报文里含本站呼号
    case cq        // CQ / CQ DX
    case myTx      // 本站发射
    case plain     // 他人之间的流量
    case worked    // 日志里已有记录

    /// 左侧 3pt 色条。色条是稀缺信号：只有「与我有关」才配拥有。
    var rail: Color? {
        switch self {
        case .toMe:  return TX.amber
        case .myTx:  return TX.txRed
        default:     return nil          // CQ 不带色条，靠 "CQ" 字样着色
        }
    }
    var rowBackground: Color {
        switch self {
        case .toMe: return TX.amber.opacity(0.09)
        default:    return .clear
        }
    }
    var messageColor: Color {
        switch self {
        case .toMe, .myTx: return TX.text1
        case .cq:          return TX.text1
        case .plain:       return TX.text2
        case .worked:      return TX.textMuted
        }
    }
    var strikethrough: Bool { self == .worked }
}
