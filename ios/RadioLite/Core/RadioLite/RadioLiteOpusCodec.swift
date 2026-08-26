import AudioToolbox
import AVFoundation
import Foundation

enum RadioLiteOpusError: LocalizedError {
    case formatUnavailable
    case converterUnavailable
    case invalidFrame
    case conversionFailed(String)
    case emptyPacket

    var errorDescription: String? {
        switch self {
        case .formatUnavailable: "iOS 无法创建 16 kHz Opus 音频格式"
        case .converterUnavailable: "此设备不提供系统 Opus 编解码器"
        case .invalidFrame: "Opus 编码需要 20 ms、320 个单声道采样"
        case .conversionFailed(let message): "Opus 转换失败：\(message)"
        case .emptyPacket: "Opus 转换没有产生音频数据"
        }
    }
}
final class RadioLiteOpusCodec {
    static let sampleRate: Double = 16_000
    static let samplesPerFrame = 320
    static let maximumPacketBytes = 1_500

    let pcmFormat: AVAudioFormat
    let opusFormat: AVAudioFormat

    private var encoder: AVAudioConverter
    private let decoder: AVAudioConverter
    private let opusFramesPerPacket: UInt32
    private(set) var bitrate: Int

    init(bitrate: Int = 20_000) throws {
        guard let pcm = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw RadioLiteOpusError.formatUnavailable }
        var selected: (AVAudioFormat, AVAudioConverter, AVAudioConverter, UInt32)?
        // Some iOS releases expose Opus only with its 48 kHz RTP clock even when
        // the decoded PCM is 16 kHz. AudioConverter performs that rate change.
        for opusRate in [Self.sampleRate, 48_000] {
            var description = AudioStreamBasicDescription(
                mSampleRate: opusRate,
                mFormatID: kAudioFormatOpus,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: UInt32(opusRate * 0.02),
                mBytesPerFrame: 0,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 0,
                mReserved: 0
            )
            if let opus = AVAudioFormat(streamDescription: &description),
               let encoder = AVAudioConverter(from: pcm, to: opus),
               let decoder = AVAudioConverter(from: opus, to: pcm) {
                selected = (opus, encoder, decoder, description.mFramesPerPacket)
                break
            }
        }
        guard let selected else {
            throw RadioLiteOpusError.converterUnavailable
        }
        self.pcmFormat = pcm
        self.opusFormat = selected.0
        self.encoder = selected.1
        self.decoder = selected.2
        self.opusFramesPerPacket = selected.3
        self.bitrate = Self.clampBitrate(bitrate)
        encoder.bitRate = self.bitrate
        encoder.primeMethod = .none
        decoder.primeMethod = .none
    }

    func setBitrate(_ value: Int) throws {
        let value = Self.clampBitrate(value)
        guard value != bitrate else { return }
        guard let replacement = AVAudioConverter(from: pcmFormat, to: opusFormat) else {
            throw RadioLiteOpusError.converterUnavailable
        }
        replacement.bitRate = value
        replacement.primeMethod = .none
        encoder = replacement
        bitrate = value
    }

    func encode(_ samples: [Float]) throws -> Data {
        guard samples.count == Self.samplesPerFrame,
              let input = AVAudioPCMBuffer(
                pcmFormat: pcmFormat,
                frameCapacity: AVAudioFrameCount(Self.samplesPerFrame)
              ), let channel = input.floatChannelData?[0] else {
            throw RadioLiteOpusError.invalidFrame
        }
        input.frameLength = AVAudioFrameCount(Self.samplesPerFrame)
        samples.withUnsafeBufferPointer { pointer in
            channel.update(from: pointer.baseAddress!, count: samples.count)
        }

        let maximum = max(Self.maximumPacketBytes, encoder.maximumOutputPacketSize)
        let output = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: maximum
        )
        var supplied = false
        var conversionError: NSError?
        let status = encoder.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            throw RadioLiteOpusError.conversionFailed(conversionError.localizedDescription)
        }
        guard status == .haveData || status == .inputRanDry || status == .endOfStream,
              output.byteLength > 0,
              output.byteLength <= Self.maximumPacketBytes else {
            throw RadioLiteOpusError.emptyPacket
        }
        return Data(bytes: output.data, count: Int(output.byteLength))
    }

    func decode(_ packet: Data) throws -> [Float] {
        guard !packet.isEmpty, packet.count <= Self.maximumPacketBytes else {
            throw RadioLiteOpusError.emptyPacket
        }
        let input = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: max(packet.count, 1)
        )
        packet.copyBytes(to: input.data.assumingMemoryBound(to: UInt8.self), count: packet.count)
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: opusFramesPerPacket,
            mDataByteSize: UInt32(packet.count)
        )

        guard let output = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: AVAudioFrameCount(Self.samplesPerFrame * 6)
        ) else { throw RadioLiteOpusError.formatUnavailable }
        var supplied = false
        var conversionError: NSError?
        let status = decoder.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            throw RadioLiteOpusError.conversionFailed(conversionError.localizedDescription)
        }
        guard status == .haveData || status == .inputRanDry || status == .endOfStream,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else {
            throw RadioLiteOpusError.emptyPacket
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    func reset() {
        encoder.reset()
        decoder.reset()
    }

    private static func clampBitrate(_ value: Int) -> Int {
        min(64_000, max(6_000, value))
    }
}
