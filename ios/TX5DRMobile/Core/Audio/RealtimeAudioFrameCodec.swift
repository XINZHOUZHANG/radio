import Foundation

struct RealtimePCMFrame: Equatable, Sendable {
    let sequence: UInt32
    let timestampMilliseconds: UInt32
    let serverSentAtMilliseconds: UInt32?
    let sampleRate: UInt32
    let channels: UInt8
    let samplesPerChannel: UInt16
    let samples: [Int16]
}

enum RealtimeAudioFrameCodecError: LocalizedError, Equatable {
    case frameTooShort
    case invalidMagic
    case unsupportedVersion(UInt8)
    case invalidFormat
    case invalidPayloadLength

    var errorDescription: String? {
        switch self {
        case .frameTooShort: "实时音频帧过短"
        case .invalidMagic: "实时音频帧标识无效"
        case .unsupportedVersion(let version): "不支持的实时音频帧版本：\(version)"
        case .invalidFormat: "实时音频采样格式无效"
        case .invalidPayloadLength: "实时音频帧长度与采样信息不匹配"
        }
    }
}

enum RealtimeAudioFrameCodec {
    static let pcmMagic: UInt32 = 0x5458_3544 // TX5D
    static let pcmVersion: UInt8 = 1
    static let diagnosticsVersion: UInt8 = 2
    static let version1HeaderBytes = 20
    static let version2HeaderBytes = 24

    static func encode(_ frame: RealtimePCMFrame) throws -> Data {
        guard frame.channels > 0, frame.sampleRate > 0, frame.samplesPerChannel > 0 else {
            throw RealtimeAudioFrameCodecError.invalidFormat
        }
        let expectedSamples = Int(frame.channels) * Int(frame.samplesPerChannel)
        guard frame.samples.count == expectedSamples else {
            throw RealtimeAudioFrameCodecError.invalidPayloadLength
        }

        let hasDiagnostics = frame.serverSentAtMilliseconds != nil
        var data = Data(capacity: (hasDiagnostics ? version2HeaderBytes : version1HeaderBytes) + frame.samples.count * 2)
        data.appendBigEndian(pcmMagic)
        data.append(hasDiagnostics ? diagnosticsVersion : pcmVersion)
        data.append(frame.channels)
        data.appendBigEndian(frame.samplesPerChannel)
        data.appendBigEndian(frame.sequence)
        data.appendBigEndian(frame.timestampMilliseconds)
        data.appendBigEndian(frame.sampleRate)
        if let serverSentAtMilliseconds = frame.serverSentAtMilliseconds {
            data.appendBigEndian(serverSentAtMilliseconds)
        }
        for sample in frame.samples {
            data.appendLittleEndian(UInt16(bitPattern: sample))
        }
        return data
    }

    static func decode(_ data: Data) throws -> RealtimePCMFrame {
        guard data.count >= version1HeaderBytes else {
            throw RealtimeAudioFrameCodecError.frameTooShort
        }
        let magic: UInt32 = try data.readBigEndian(at: 0)
        guard magic == pcmMagic else { throw RealtimeAudioFrameCodecError.invalidMagic }

        let version = data[4]
        guard version == pcmVersion || version == diagnosticsVersion else {
            throw RealtimeAudioFrameCodecError.unsupportedVersion(version)
        }
        let headerBytes = version == diagnosticsVersion ? version2HeaderBytes : version1HeaderBytes
        guard data.count >= headerBytes else { throw RealtimeAudioFrameCodecError.frameTooShort }

        let channels = data[5]
        let samplesPerChannel: UInt16 = try data.readBigEndian(at: 6)
        let sequence: UInt32 = try data.readBigEndian(at: 8)
        let timestamp: UInt32 = try data.readBigEndian(at: 12)
        let sampleRate: UInt32 = try data.readBigEndian(at: 16)
        let serverSentAt: UInt32? = version == diagnosticsVersion ? try data.readBigEndian(at: 20) : nil
        guard channels > 0, samplesPerChannel > 0, sampleRate > 0 else {
            throw RealtimeAudioFrameCodecError.invalidFormat
        }

        let payloadBytes = data.count - headerBytes
        guard payloadBytes.isMultiple(of: 2) else {
            throw RealtimeAudioFrameCodecError.invalidPayloadLength
        }
        let expectedSamples = Int(channels) * Int(samplesPerChannel)
        guard payloadBytes / 2 == expectedSamples else {
            throw RealtimeAudioFrameCodecError.invalidPayloadLength
        }

        var samples: [Int16] = []
        samples.reserveCapacity(expectedSamples)
        var offset = headerBytes
        while offset < data.count {
            let raw: UInt16 = try data.readLittleEndian(at: offset)
            samples.append(Int16(bitPattern: raw))
            offset += 2
        }

        return RealtimePCMFrame(
            sequence: sequence,
            timestampMilliseconds: timestamp,
            serverSentAtMilliseconds: serverSentAt,
            sampleRate: sampleRate,
            channels: channels,
            samplesPerChannel: samplesPerChannel,
            samples: samples
        )
    }
}

private extension Data {
    mutating func appendBigEndian<Value: FixedWidthInteger>(_ value: Value) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    func readBigEndian<Value: FixedWidthInteger>(at offset: Int) throws -> Value {
        try readInteger(at: offset, byteOrder: .big)
    }

    func readLittleEndian<Value: FixedWidthInteger>(at offset: Int) throws -> Value {
        try readInteger(at: offset, byteOrder: .little)
    }

    func readInteger<Value: FixedWidthInteger>(at offset: Int, byteOrder: ByteOrder) throws -> Value {
        let width = MemoryLayout<Value>.size
        guard offset >= 0, offset + width <= count else {
            throw RealtimeAudioFrameCodecError.frameTooShort
        }
        var value: Value = 0
        switch byteOrder {
        case .big:
            for byte in self[offset..<(offset + width)] {
                value = (value << 8) | Value(byte)
            }
        case .little:
            for (shift, byte) in self[offset..<(offset + width)].enumerated() {
                value |= Value(byte) << Value(shift * 8)
            }
        }
        return value
    }

    enum ByteOrder { case big, little }
}
