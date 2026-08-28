import Foundation

enum RadioLiteMediaKind: UInt8, Codable, Sendable {
    case audioDownlink = 1
    case audioUplink = 2
    case spectrum = 3
    case statistics = 4
}
struct RadioLiteMediaFrame: Equatable, Sendable {
    static let version: UInt8 = 1
    static let headerBytes = 16

    let kind: RadioLiteMediaKind
    let flags: UInt8
    let radioSlot: UInt8
    let sequence: UInt32
    let timestampMicroseconds: UInt64
    let payload: Data
}

struct RadioLiteSpectrumFrame: Equatable, Sendable {
    let centerFrequencyHz: UInt64
    let spanHz: UInt32
    let noiseFloorTenthsDBm: Int16
    let bins: [UInt8]
}

struct RadioLiteSpectrumCapability: Codable, Equatable, Sendable {
    let available: Bool
    let source: String
    let simulated: Bool
    let supportsWaterfall: Bool
    let maxBins: Int
    let maxFps: Int
    let spanHz: Int?
    let reason: String?

    static func unavailable(reason: String) -> Self {
        Self(
            available: false,
            source: "none",
            simulated: false,
            supportsWaterfall: false,
            maxBins: 0,
            maxFps: 0,
            spanHz: nil,
            reason: reason
        )
    }
}

struct RadioLiteSpectrumHistory: Equatable, Sendable {
    private struct Axis: Equatable, Sendable {
        let centerFrequencyHz: UInt64
        let spanHz: UInt32
        let binCount: Int
    }

    let maxRows: Int
    let maxColumns: Int
    private(set) var rows: [[UInt8]] = []
    private var axis: Axis?

    init(maxRows: Int = 96, maxColumns: Int = 256) {
        self.maxRows = max(1, maxRows)
        self.maxColumns = max(1, maxColumns)
    }

    mutating func append(_ frame: RadioLiteSpectrumFrame) {
        let nextAxis = Axis(
            centerFrequencyHz: frame.centerFrequencyHz,
            spanHz: frame.spanHz,
            binCount: frame.bins.count
        )
        if axis != nextAxis {
            rows.removeAll(keepingCapacity: true)
            axis = nextAxis
        }
        rows.append(downsample(frame.bins))
        if rows.count > maxRows {
            rows.removeFirst(rows.count - maxRows)
        }
    }

    mutating func reset() {
        rows.removeAll(keepingCapacity: false)
        axis = nil
    }

    private func downsample(_ bins: [UInt8]) -> [UInt8] {
        guard bins.count > maxColumns else { return bins }
        return (0..<maxColumns).map { column in
            let start = column * bins.count / maxColumns
            let end = max(start + 1, (column + 1) * bins.count / maxColumns)
            return bins[start..<min(end, bins.count)].max() ?? 0
        }
    }
}

enum RadioLiteMediaFrameError: LocalizedError, Equatable {
    case invalidLength
    case unsupportedVersion
    case unknownKind
    case payloadTooLarge
    case malformedSpectrum

    var errorDescription: String? {
        switch self {
        case .invalidLength: "媒体帧长度无效"
        case .unsupportedVersion: "媒体协议版本不受支持"
        case .unknownKind: "媒体帧类型未知"
        case .payloadTooLarge: "媒体负载超过 65520 字节"
        case .malformedSpectrum: "频谱帧格式无效"
        }
    }
}

enum RadioLiteMediaFrameCodec {
    static func encode(_ frame: RadioLiteMediaFrame) throws -> Data {
        guard frame.payload.count <= 65_536 - RadioLiteMediaFrame.headerBytes else {
            throw RadioLiteMediaFrameError.payloadTooLarge
        }
        var data = Data(capacity: RadioLiteMediaFrame.headerBytes + frame.payload.count)
        data.append(RadioLiteMediaFrame.version)
        data.append(frame.kind.rawValue)
        data.append(frame.flags)
        data.append(frame.radioSlot)
        append(frame.sequence, to: &data)
        append(frame.timestampMicroseconds, to: &data)
        data.append(frame.payload)
        return data
    }

    static func decode(_ data: Data) throws -> RadioLiteMediaFrame {
        guard data.count >= RadioLiteMediaFrame.headerBytes, data.count <= 65_536 else {
            throw RadioLiteMediaFrameError.invalidLength
        }
        guard data[0] == RadioLiteMediaFrame.version else {
            throw RadioLiteMediaFrameError.unsupportedVersion
        }
        guard let kind = RadioLiteMediaKind(rawValue: data[1]) else {
            throw RadioLiteMediaFrameError.unknownKind
        }
        return RadioLiteMediaFrame(
            kind: kind,
            flags: data[2],
            radioSlot: data[3],
            sequence: readUInt32(data, at: 4),
            timestampMicroseconds: readUInt64(data, at: 8),
            payload: data.subdata(in: RadioLiteMediaFrame.headerBytes..<data.count)
        )
    }

    static func decodeSpectrum(_ payload: Data) throws -> RadioLiteSpectrumFrame {
        guard payload.count >= 16 else { throw RadioLiteMediaFrameError.malformedSpectrum }
        let count = Int(readUInt16(payload, at: 14))
        guard (16...4_096).contains(count), payload.count == 16 + count else {
            throw RadioLiteMediaFrameError.malformedSpectrum
        }
        return RadioLiteSpectrumFrame(
            centerFrequencyHz: readUInt64(payload, at: 0),
            spanHz: readUInt32(payload, at: 8),
            noiseFloorTenthsDBm: Int16(bitPattern: readUInt16(payload, at: 12)),
            bins: Array(payload[16...])
        )
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 56))
        data.append(UInt8(truncatingIfNeeded: value >> 48))
        data.append(UInt8(truncatingIfNeeded: value >> 40))
        data.append(UInt8(truncatingIfNeeded: value >> 32))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<(offset + MemoryLayout<UInt64>.size) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
    }
}
