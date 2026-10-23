import XCTest
@testable import ContinuityCore

final class BudsPlaybackPolicyTests: XCTestCase {
    private func process(_ bundle: String?, _ name: String? = nil, running: Bool = true, devices: [UInt32] = [7]) -> BudsAudioProcess {
        .init(objectID: 1, bundleID: bundle, processName: name, runningOutput: running, devices: devices)
    }
    func testSystemSoundOnlyDoesNotTriggerButSimultaneousAppAudioDoes() {
        let beep = process("com.apple.audio.SystemSoundServer")
        XCTAssertFalse(BudsPlaybackPolicy.hasAppPlayback([beep], output: 7))
        XCTAssertFalse(BudsPlaybackPolicy.hasAppPlayback([process(nil, "systemsoundserverd")], output: 7))
        XCTAssertFalse(BudsPlaybackPolicy.hasAppPlayback([process("com.apple.notificationcenterui")], output: 7))
        XCTAssertTrue(BudsPlaybackPolicy.hasAppPlayback([beep, process("com.apple.Music")], output: 7))
        XCTAssertTrue(BudsPlaybackPolicy.hasAppPlayback([process("com.google.Chrome.helper")], output: 7))
        XCTAssertTrue(BudsPlaybackPolicy.hasAppPlayback([process(nil, "afplay")], output: 7))
    }
    func testRoutingAndUnknownMetadataNeverTriggerATakeover() {
        XCTAssertFalse(BudsPlaybackPolicy.hasAppPlayback(nil, output: 7))
        XCTAssertFalse(BudsPlaybackPolicy.hasAppPlayback([process(nil)], output: 7))
        XCTAssertFalse(BudsPlaybackPolicy.hasAppPlayback([process("com.apple.Music", running: false)], output: 7))
        XCTAssertFalse(BudsPlaybackPolicy.hasAppPlayback([process("com.apple.Music", devices: [8])], output: 7))
        XCTAssertFalse(BudsPlaybackPolicy.hasAppPlayback([process("com.apple.Music")], output: 0))
        XCTAssertFalse(BudsPlaybackPolicy.isSystemSound(process("com.apple.audio.SystemSoundServer.other")))
    }
}
