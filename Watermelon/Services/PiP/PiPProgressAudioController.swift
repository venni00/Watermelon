import AVFoundation
import os.log

protocol PiPProgressAudioPlaying: AnyObject {
    var numberOfLoops: Int { get set }
    var volume: Float { get set }
    func play() -> Bool
    func stop()
}

extension AVAudioPlayer: PiPProgressAudioPlaying {}

final class PiPProgressAudioController: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.zizicici.watermelon", category: "PiPAudio")
    private let queue = DispatchQueue(label: "watermelon.pip.audio", qos: .userInitiated)
    private let configureSession: @Sendable () throws -> Void
    private let makePlayer: @Sendable (URL) throws -> any PiPProgressAudioPlaying

    // Players stay on the serial queue so a pending start cannot overtake a stop.
    private var ambientPlayer: (any PiPProgressAudioPlaying)?
    private var chimePlayer: (any PiPProgressAudioPlaying)?

    init(
        configureSession: @escaping @Sendable () throws -> Void = {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        },
        makePlayer: @escaping @Sendable (URL) throws -> any PiPProgressAudioPlaying = {
            try AVAudioPlayer(contentsOf: $0)
        }
    ) {
        self.configureSession = configureSession
        self.makePlayer = makePlayer
    }

    func prepareSession(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async {
            let succeeded: Bool
            do {
                try self.configureSession()
                succeeded = true
            } catch {
                Self.log.error("Failed to prepare PiP audio: \(error.localizedDescription, privacy: .public)")
                succeeded = false
            }
            DispatchQueue.main.async { completion(succeeded) }
        }
    }

    func startAmbientLoop(url: URL, volume: Float) {
        queue.async {
            if let player = self.ambientPlayer {
                player.volume = volume
                return
            }
            do {
                let player = try self.makePlayer(url)
                player.numberOfLoops = -1
                player.volume = volume
                if player.play() {
                    self.ambientPlayer = player
                }
            } catch {
                Self.log.error("Failed to start PiP audio: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stopAmbientLoop() {
        queue.async {
            self.ambientPlayer?.stop()
            self.ambientPlayer = nil
        }
    }

    func playCompletionChime(url: URL) {
        queue.async {
            do {
                self.chimePlayer?.stop()
                self.chimePlayer = nil
                let player = try self.makePlayer(url)
                player.volume = 0.4
                if player.play() {
                    self.chimePlayer = player
                }
            } catch {
                Self.log.error("Failed to play PiP completion sound: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
