import AVFoundation

/// Converts the microphone signal explicitly to mono before sample-rate conversion.
/// The same converter is exercised by the real tap and synthetic format tests.
final class CallingCaptureConverter {
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var rate: Double = 0
    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let frames = Int(input.frameLength), inputRate = input.format.sampleRate
        guard frames > 0, frames <= 65536, inputRate >= 8000, inputRate <= 192000,
              input.format.channelCount > 0, input.format.channelCount <= 32 else {
            throw ContinuityError.message("Invalid microphone capture format.")
        }
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: input.frameLength), let destination = source.floatChannelData?[0] else {
            throw ContinuityError.message("Could not allocate microphone conversion buffer.")
        }
        if converter == nil || rate != inputRate {
            converter = AVAudioConverter(from: mono, to: target); rate = inputRate
        }
        guard let converter else { throw ContinuityError.message("Could not initialize microphone conversion.") }
        let stride = input.stride
        if let samples = input.floatChannelData {
            for i in 0..<frames { destination[i] = samples[0][i * stride] }
        } else if let samples = input.int16ChannelData {
            for i in 0..<frames { destination[i] = Float(samples[0][i * stride]) / 32768 }
        } else if let samples = input.int32ChannelData {
            for i in 0..<frames { destination[i] = Float(samples[0][i * stride]) / 2147483648 }
        } else { throw ContinuityError.message("Unsupported microphone sample representation.") }
        source.frameLength = input.frameLength
        let capacity = AVAudioFrameCount(Double(frames) * 16000 / inputRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw ContinuityError.message("Could not allocate converted microphone buffer.")
        }
        var fed = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if fed { state.pointee = .noDataNow; return nil }
            fed = true; state.pointee = .haveData; return source
        }
        if let error { throw error }
        guard status != .error else { throw ContinuityError.message("Microphone conversion failed.") }
        return output
    }
}
