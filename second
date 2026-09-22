import AVFoundation

class AudioEngine {
    private let engine = AVAudioEngine()
    private var players: [String: AVAudioPlayerNode] = [:]
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private let audioSession = AVAudioSession.sharedInstance()

    init() {
        setupAudioSession()
        engine.prepare()
        startEngine()
    }

    private func setupAudioSession() {
        do {
            try audioSession.setCategory(AVAudioSessionCategoryPlayback, with: .mixWithOthers)
            try audioSession.setActive(true)
            try audioSession.setPreferredIOBufferDuration(512.0 / 44100.0)
        } catch {
            print("Error configurando la sesión de audio: \(error)")
        }
    }

    private func startEngine() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            print("Error iniciando el motor de audio: \(error)")
        }
    }

    func loadFile(url: URL, forTrack trackID: String) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return false }
            try file.read(into: buffer)
            buffers[trackID] = buffer

            if let oldPlayer = players[trackID] {
                oldPlayer.stop()
                engine.detach(oldPlayer)
                players[trackID] = nil
            }

            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players[trackID] = player
            startEngine()
            return true
        } catch {
            print("Error cargando archivo: \(error)")
            return false
        }
    }

    func trigger(trackID: String, volume: Float) {
        guard let player = players[trackID],
              let buffer = buffers[trackID] else { return }
        player.volume = volume
        if !player.isPlaying {
            player.play()
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    func stopAll() {
        for player in players.values {
            player.stop()
        }
    }

    func removeTrack(trackID: String) {
        if let player = players[trackID] {
            player.stop()
            engine.detach(player)
        }
        players[trackID] = nil
        buffers[trackID] = nil
    }
}