import XCTest
@testable import Watermelon

@MainActor
final class PiPProgressAudioControllerTests: XCTestCase {
    func testAudioOperationsRunOffMainThreadInOrder() async {
        let recorder = AudioRecorder()
        let controller = PiPProgressAudioController(
            configureSession: { recorder.record("configure") },
            makePlayer: { url in
                recorder.record("create:\(url.lastPathComponent)")
                return TestAudioPlayer(name: url.lastPathComponent, recorder: recorder)
            }
        )
        let prepared = expectation(description: "Prepared on main thread")
        controller.prepareSession { succeeded in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(succeeded)
            prepared.fulfill()
        }
        let ambientURL = URL(fileURLWithPath: "/ambient.mp3")
        controller.startAmbientLoop(url: ambientURL, volume: 0.15)
        controller.startAmbientLoop(url: ambientURL, volume: 0.00001)
        controller.stopAmbientLoop()
        controller.startAmbientLoop(url: ambientURL, volume: 0.15)
        controller.stopAmbientLoop()
        controller.playCompletionChime(url: URL(fileURLWithPath: "/complete.wav"))
        let drained = expectation(description: "Queued operations completed")
        controller.prepareSession { _ in drained.fulfill() }

        await fulfillment(of: [prepared, drained], timeout: 3)

        XCTAssertEqual(recorder.events, [
            "configure",
            "create:ambient.mp3", "loops:-1", "volume:0.15", "play:ambient.mp3",
            "volume:1e-05", "stop:ambient.mp3",
            "create:ambient.mp3", "loops:-1", "volume:0.15", "play:ambient.mp3",
            "stop:ambient.mp3",
            "create:complete.wav", "volume:0.4", "play:complete.wav",
            "configure"
        ])
    }

    func testPreparationFailureReturnsToMainThread() async {
        let controller = PiPProgressAudioController(configureSession: {
            XCTAssertFalse(Thread.isMainThread)
            throw CocoaError(.fileReadUnknown)
        })
        let prepared = expectation(description: "Preparation failed")
        controller.prepareSession { succeeded in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(succeeded)
            prepared.fulfill()
        }

        await fulfillment(of: [prepared], timeout: 3)
    }

    func testFailedPlaybackCanBeRetried() async {
        let recorder = AudioRecorder()
        let controller = PiPProgressAudioController(
            configureSession: {},
            makePlayer: { url in
                recorder.record("create")
                return TestAudioPlayer(name: url.lastPathComponent, recorder: recorder, playResult: false)
            }
        )
        let url = URL(fileURLWithPath: "/ambient.mp3")
        controller.startAmbientLoop(url: url, volume: 0.15)
        controller.startAmbientLoop(url: url, volume: 0.15)
        controller.stopAmbientLoop()
        let drained = expectation(description: "Retries completed")
        controller.prepareSession { _ in drained.fulfill() }

        await fulfillment(of: [drained], timeout: 3)

        XCTAssertEqual(recorder.events.filter { $0 == "create" }.count, 2)
        XCTAssertFalse(recorder.events.contains("stop:ambient.mp3"))
    }
}

private final class AudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    var events: [String] { lock.withLock { recordedEvents } }

    func record(_ event: String) {
        XCTAssertFalse(Thread.isMainThread)
        lock.withLock { recordedEvents.append(event) }
    }
}

private final class TestAudioPlayer: PiPProgressAudioPlaying {
    private let name: String
    private let recorder: AudioRecorder
    private let playResult: Bool

    var numberOfLoops = 0 {
        didSet { recorder.record("loops:\(numberOfLoops)") }
    }

    var volume: Float = 1 {
        didSet { recorder.record("volume:\(volume)") }
    }

    init(name: String, recorder: AudioRecorder, playResult: Bool = true) {
        self.name = name
        self.recorder = recorder
        self.playResult = playResult
    }

    func play() -> Bool {
        recorder.record("play:\(name)")
        return playResult
    }

    func stop() {
        recorder.record("stop:\(name)")
    }
}
