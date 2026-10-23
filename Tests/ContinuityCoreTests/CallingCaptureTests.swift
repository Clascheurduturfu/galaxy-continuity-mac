import XCTest
import AVFoundation
@testable import ContinuityCore

final class CallingCaptureTests: XCTestCase {
    func testRealCaptureConverterWithMonoAndMultichannelInput() throws {
        for channels in [AVAudioChannelCount(1), 2, 5] {
            for interleaved in [false, true] {
                for representation in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
                    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
                    let format = try XCTUnwrap(AVAudioFormat(commonFormat: representation, sampleRate: 48000, interleaved: interleaved, channelLayout: layout), "format channels=\(channels) interleaved=\(interleaved) representation=\(representation.rawValue)")
                    let converter = CallingCaptureConverter()
                    var total = 0, energy = 0.0
                    for packet in 0..<12 {
                        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
                        input.frameLength = 960
                        for channel in 0..<Int(channels) {
                            for i in 0..<960 {
                                let tone = channel == 0 ? Float(sin(Double(packet * 960 + i) * 2 * .pi * 440 / 48000) * 0.2) : 0
                                if let data = input.floatChannelData { data[interleaved ? 0 : channel][i * input.stride + (interleaved ? channel : 0)] = tone }
                                if let data = input.int16ChannelData { data[interleaved ? 0 : channel][i * input.stride + (interleaved ? channel : 0)] = Int16(tone * 32767) }
                            }
                        }
                        let output = try converter.convert(input)
                        total += Int(output.frameLength)
                        for i in 0..<Int(output.frameLength) { let value = Double(output.int16ChannelData![0][i]); energy += value * value }
                    }
                    XCTAssertGreaterThan(total, 3500); XCTAssertLessThan(total, 3900)
                    XCTAssertGreaterThan(sqrt(energy / Double(total)), 1000)
                }
            }
        }
    }
}
