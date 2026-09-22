import UIKit

class Sequencer: NSObject {
    static let shared = Sequencer()

    var tracks: [Track] = []
    var currentStep: Int = -1
    var isPlaying: Bool = false
    var bpm: Double = 120
    let stepsCount = 16

    let audio = AudioEngine()
    private var timer: DispatchSourceTimer?
    private var step = 0

    private override init() {
        super.init()
        for i in 0..<4 {
            let color = UIColor(hue: CGFloat(i) / 4.0, saturation: 0.8, brightness: 0.9, alpha: 1.0)
            tracks.append(Track(name: "Pista \(i + 1)", color: color))
        }
    }

    func start() {
        guard !isPlaying else { return }
        isPlaying = true
        step = 0
        startTimer()
    }

    func stop() {
        isPlaying = false
        timer?.cancel()
        timer = nil
        audio.stopAll()
        currentStep = -1
        step = 0
    }

    private func startTimer() {
        let interval = 60.0 / bpm / 4.0
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        timer = t
    }

    private func tick() {
        currentStep = step
        for track in tracks where !track.isMuted && track.hasAudio {
            if track.steps[step] {
                audio.trigger(trackID: track.id, volume: track.volume)
            }
        }
        step = (step + 1) % stepsCount
        NotificationCenter.default.post(name: .sequencerDidTick, object: self)
    }

    func toggleStep(trackIndex: Int, stepIndex: Int) {
        guard tracks.indices.contains(trackIndex),
              tracks[trackIndex].steps.indices.contains(stepIndex) else { return }
        tracks[trackIndex].steps[stepIndex].toggle()
    }

    func addTrack() {
        let color = UIColor(hue: CGFloat(tracks.count % 8) / 8.0, saturation: 0.8, brightness: 0.9, alpha: 1.0)
        tracks.append(Track(name: "Pista \(tracks.count + 1)", color: color))
    }

    func removeTrack(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        audio.removeTrack(trackID: tracks[index].id)
        tracks.remove(at: index)
    }

    func assignFile(url: URL, toTrack index: Int) {
        guard tracks.indices.contains(index) else { return }
        let success = audio.loadFile(url: url, forTrack: tracks[index].id)
        if success {
            tracks[index].url = url
            tracks[index].name = url.deletingPathExtension().lastPathComponent
        }
    }

    func clearPattern() {
        for i in tracks.indices {
            tracks[i].steps = Array(repeating: false, count: stepsCount)
        }
    }
}

extension Notification.Name {
    static let sequencerDidTick = Notification.Name("sequencerDidTick")
}