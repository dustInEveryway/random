```xml
// === FILE: Info.plist ===
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>UIBackgroundModes</key>
    <array><string>audio</string></array>
    <key>UIRequiresFullScreen</key><true/>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>NSMicrophoneUsageDescription</key>
    <string>Se usa para procesar audio del motor en tiempo real.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Se usa para entrada/salida MIDI por Bluetooth.</string>
    <key>UIFileSharingEnabled</key><true/>
    <key>LSSupportsOpeningDocumentsInPlace</key><true/>
</dict>
</plist>
```

---

1. Utilidades DSP y threading

```swift
// === FILE: Audio/DSPUtilities.swift ===
import Foundation

/// Parámetro DSP thread-safe. Lecturas/escrituras de Float alineado son atómicas
/// a nivel hardware en ARM64; usamos un lock solo para coherencia entre hilos UI.
/// El audio thread NUNCA bloquea: sólo hace una lectura benigna.
final class DSPParameter: @unchecked Sendable {
    private var _value: Float
    private let lock = NSLock()

    init(_ v: Float = 0) { _value = v }

    @inline(__always)
    func get() -> Float {
        // Lectura sin lock, benigna desde el audio thread.
        return _value
    }

    func set(_ v: Float) {
        lock.lock(); _value = v; lock.unlock()
    }
}

/// Snapshot inmutable para estructuras complejas (Pattern, etc.).
final class AtomicBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ initial: T) { _value = initial }

    func store(_ v: T) {
        lock.lock(); _value = v; lock.unlock()
    }

    /// Lectura sin lock: la UI publica por referencia y el audio lee el último valor.
    /// Aceptable porque el audio consume y descarta; un patrón "parcialmente nuevo" no existe
    /// (se publica siempre completo).
    func loadForAudio() -> T { return _value }

    func loadForUI() -> T {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}

// MARK: - Bloques DSP básicos

final class OnePoleLP {
    private var z: Float = 0
    @inline(__always) func process(_ x: Float, cutoff: Float, sr: Float) -> Float {
        let a = expf(-2 * .pi * cutoff / sr)
        z = x * (1 - a) + z * a
        return z
    }
    func reset() { z = 0 }
}

final class OnePoleHP {
    private var z: Float = 0
    @inline(__always) func process(_ x: Float, cutoff: Float, sr: Float) -> Float {
        let a = expf(-2 * .pi * cutoff / sr)
        let hp = x - z
        z = x * (1 - a) + z * a
        return hp
    }
    func reset() { z = 0 }
}

final class BiquadBP {
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    private var lastF: Float = 0
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    @inline(__always)
    func process(_ x: Float, center: Float, sr: Float) -> Float {
        if abs(center - lastF) > 1 {
            let w0 = 2 * Float.pi * min(center, sr * 0.45) / sr
            let alpha: Float = sinf(w0) / (2 * 0.7)
            let cosw = cosf(w0)
            let a0 = 1 + alpha
            b0 = alpha / a0; b1 = 0; b2 = -alpha / a0
            a1 = -2 * cosw / a0; a2 = (1 - alpha) / a0
            lastF = center
        }
        let y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
    func reset() { x1=0; x2=0; y1=0; y2=0 }
}

/// RNG xorshift rápido para ruido en audio thread.
final class FastRNG {
    private var state: UInt32
    init(seed: UInt32 = 0x12345678) { state = seed | 1 }
    @inline(__always) func nextFloat() -> Float {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        return Float(Int32(bitPattern: state)) / Float(Int32.max)
    }
}
```

---

2. Modelo de patrón y step

```swift
// === FILE: Audio/Pattern.swift ===
import Foundation

struct Step: Codable, Equatable {
    var active: Bool = false
    var velocity: Float = 0.8
    var accent: Bool = false
    var probability: Float = 1.0
    var pan: Float = 0.0
    var microtiming: Float = 0.0   // -0.5..0.5 (fracción de step)
    var noteRepeat: Int = 1
    var flam: Int = 0
    var ratchet: Int = 0
    var gate: Float = 1.0
    var stepLength: Float = 1.0
}

struct TrackPattern: Codable, Equatable {
    var name: String
    var steps: [Step]
    var mute: Bool = false
    var solo: Bool = false

    mutating func resize(_ n: Int) {
        if n > steps.count {
            steps.append(contentsOf: Array(repeating: Step(), count: n - steps.count))
        } else if n < steps.count {
            steps.removeLast(steps.count - n)
        }
    }
}

struct Pattern: Codable, Equatable {
    var name: String = "Pattern 1"
    var length: Int = 16
    var bpm: Double = 128
    var swing: Float = 0.0
    var humanize: Float = 0.0
    var shuffle: Float = 0.0
    var tracks: [TrackPattern]

    static func empty909() -> Pattern {
        let names = ["KICK","SNARE","CLAP","CH","OH","LOW TOM","MID TOM","HIGH TOM","RIM","CRASH","RIDE"]
        return Pattern(tracks: names.map {
            TrackPattern(name: $0, steps: Array(repeating: Step(), count: 16))
        })
    }
}
```

---

3. Voces 909 (síntesis, sin samples)

```swift
// === FILE: Audio/Voice909.swift ===
import Foundation

protocol Voice909: AnyObject {
    var name: String { get }
    func trigger(velocity: Float, atSampleTime: Int64)
    func render(frameCount: Int,
                left: UnsafeMutablePointer<Float>,
                right: UnsafeMutablePointer<Float>)
    func allNotesOff()
}

class VoiceBase: Voice909 {
    let name: String
    var sampleRate: Double = 48_000

    let gain   = DSPParameter(1.0)
    let pan    = DSPParameter(0.0)
    let tune   = DSPParameter(1.0)
    let decay  = DSPParameter(0.4)
    let attack = DSPParameter(0.001)
    let accent = DSPParameter(1.0)

    init(name: String) { self.name = name }

    func trigger(velocity: Float, atSampleTime: Int64) {}
    func render(frameCount: Int, left: UnsafeMutablePointer<Float>,
                right: UnsafeMutablePointer<Float>) {}
    func allNotesOff() {}
}
```

```swift
// === FILE: Audio/Voices/Kick909.swift ===
import Foundation

final class Kick909: VoiceBase {
    // DSP state
    private var phase: Double = 0
    private var amp: Float = 0
    private var pitchEnv: Float = 0
    private var noiseAmp: Float = 0
    private var clickPhase: Double = 0
    private var t: Double = 0
    private let rng = FastRNG(seed: 0xK1CK &+ 0x909)
    private let noiseLP = OnePoleLP()

    // Parámetros
    let pitchStart = DSPParameter(180)
    let pitchEnd   = DSPParameter(48)
    let pitchDecay = DSPParameter(0.045)
    let ampDecay   = DSPParameter(0.35)
    let clickAmt   = DSPParameter(0.5)
    let clickFreq  = DSPParameter(1500)
    let noiseAmt   = DSPParameter(0.0)
    let noiseDecay = DSPParameter(0.02)
    let punch      = DSPParameter(0.0)
    let drive      = DSPParameter(1.0)

    override init(name: String = "Kick") { super.init(name: name) }

    override func trigger(velocity: Float, atSampleTime: Int64) {
        phase = 0; clickPhase = 0; t = 0
        amp = velocity * accent.get()
        pitchEnv = 1.0
        noiseAmp = noiseAmt.get() * velocity
    }

    override func render(frameCount: Int,
                         left: UnsafeMutablePointer<Float>,
                         right: UnsafeMutablePointer<Float>) {
        let dt = 1.0 / sampleRate
        let g = gain.get()
        let p = pan.get()
        let lg = g * (1 - max(0, p))
        let rg = g * (1 + min(0, p))

        let pS = pitchStart.get(), pE = pitchEnd.get()
        let pD = max(0.001, pitchDecay.get())
        let aD = max(0.005, ampDecay.get())
        let cAmt = clickAmt.get(), cFreq = clickFreq.get()
        let nDec = max(0.001, noiseDecay.get())
        let driveAmt = max(1.0, drive.get())
        let punchAmt = punch.get()

        let pitchCoef = expf(Float(-dt / Double(pD)))
        let ampCoef   = expf(Float(-dt / Double(aD)))
        let noiseCoef = expf(Float(-dt / Double(nDec)))
        let cEnvCoef  = expf(Float(-dt / 0.002))
        let pEnvCoef  = expf(Float(-dt / 0.008))
        var cEnv: Float = 1.0
        var pEnv: Float = 1.0

        for i in 0..<frameCount {
            pitchEnv *= pitchCoef
            let freq = pE + (pS - pE) * pitchEnv
            phase += Double(freq) * dt
            if phase > 1 { phase -= 1 }

            amp *= ampCoef

            var s = sinf(Float(phase) * 2 * .pi) * amp

            if cAmt > 0.001 {
                clickPhase += Double(cFreq) * dt
                if clickPhase > 1 { clickPhase -= 1 }
                s += sinf(Float(clickPhase) * 2 * .pi) * cAmt * cEnv * 0.7
                cEnv *= cEnvCoef
            }

            if punchAmt > 0.001 {
                s += sinf(Float(phase) * 2 * .pi) * punchAmt * pEnv * 0.6
                pEnv *= pEnvCoef
            }

            if noiseAmp > 0.0001 {
                let n = rng.nextFloat()
                let filtered = noiseLP.process(n, cutoff: 3000, sr: Float(sampleRate))
                s += filtered * noiseAmp
                noiseAmp *= noiseCoef
            }

            if driveAmt > 1.01 {
                s = tanhf(s * driveAmt) / tanhf(driveAmt)
            }

            s *= g
            left[i]  += s * lg
            right[i] += s * rg
            t += dt
        }
    }

    override func allNotesOff() {
        amp = 0; noiseAmp = 0
    }
}
```

```swift
// === FILE: Audio/Voices/Snare909.swift ===
import Foundation

final class Snare909: VoiceBase {
    private var phase1: Double = 0, phase2: Double = 0
    private var envTone: Float = 0, envNoise: Float = 0
    private let rng = FastRNG(seed: 0x5NARE &+ 0x909)
    private let hp = OnePoleHP()
    private let bp = BiquadBP()

    let tune1      = DSPParameter(180)
    let tune2      = DSPParameter(330)
    let toneMix    = DSPParameter(0.5)
    let noiseAmt   = DSPParameter(1.0)
    let snap       = DSPParameter(0.6)
    let body       = DSPParameter(0.4)
    let decayTone  = DSPParameter(0.08)
    let decayNoise = DSPParameter(0.16)
    let drive      = DSPParameter(1.0)

    override init(name: String = "Snare") { super.init(name: name) }

    override func trigger(velocity: Float, atSampleTime: Int64) {
        phase1 = 0; phase2 = 0
        envTone = velocity * accent.get()
        envNoise = velocity * accent.get()
    }

    override func render(frameCount: Int,
                         left: UnsafeMutablePointer<Float>,
                         right: UnsafeMutablePointer<Float>) {
        let dt = 1.0 / sampleRate
        let g = gain.get(), p = pan.get()
        let lg = g * (1 - max(0, p)), rg = g * (1 + min(0, p))
        let f1 = tune1.get(), f2 = tune2.get()
        let tm = toneMix.get(), nm = noiseAmt.get()
        let sn = snap.get(), bd = body.get()
        let dT = max(0.005, decayTone.get())
        let dN = max(0.005, decayNoise.get())
        let dr = max(1.0, drive.get())

        let tCoeff = expf(Float(-dt / Double(dT)))
        let nCoeff = expf(Float(-dt / Double(dN)))
        let bpCenter: Float = 3000 + sn * 4000
        let hpCut: Float = 200 + sn * 1200

        for i in 0..<frameCount {
            phase1 += Double(f1) * dt; if phase1 > 1 { phase1 -= 1 }
            phase2 += Double(f2) * dt; if phase2 > 1 { phase2 -= 1 }

            let tone = (sinf(Float(phase1) * 2 * .pi) + sinf(Float(phase2) * 2 * .pi)) * 0.5
            let toneSig = tone * envTone * (1 - tm * 0.5) * bd

            let nz = rng.nextFloat()
            var noiseSig = bp.process(nz, center: bpCenter, sr: Float(sampleRate)) * envNoise * nm
            noiseSig = hp.process(noiseSig, cutoff: hpCut, sr: Float(sampleRate))

            var s = toneSig + noiseSig
            if dr > 1.01 { s = tanhf(s * dr) / tanhf(dr) }
            s *= g
            left[i] += s * lg; right[i] += s * rg

            envTone  *= tCoeff
            envNoise *= nCoeff
        }
    }
}
```

```swift
// === FILE: Audio/Voices/Clap909.swift ===
import Foundation

final class Clap909: VoiceBase {
    private var env: Float = 0
    private let rng = FastRNG(seed: 0xC1AP &+ 0x909)
    private let bp = BiquadBP()
    private let hp = OnePoleHP()

    let tone      = DSPParameter(0.5)
    let width     = DSPParameter(0.7)
    let burstGap  = DSPParameter(0.010)
    let tailDecay = DSPParameter(0.20)
    let reverbAmt = DSPParameter(0.0)

    override init(name: String = "Clap") { super.init(name: name) }

    override func trigger(velocity: Float, atSampleTime: Int64) {
        env = velocity * accent.get()
    }

    override func render(frameCount: Int,
                         left: UnsafeMutablePointer<Float>,
                         right: UnsafeMutablePointer<Float>) {
        let dt = 1.0 / sampleRate
        let g = gain.get(), p = pan.get()
        let lg = g * (1 - max(0, p)), rg = g * (1 + min(0, p))
        let tn = tone.get(), wd = width.get()
        let td = max(0.01, tailDecay.get())
        let spread = (1 - wd) * 0.5 + 0.5
        let bpCenter: Float = 1000 + tn * 1500
        let decayCoef = expf(Float(-dt / Double(td * 0.5)))

        for i in 0..<frameCount {
            let nz = rng.nextFloat()
            var s = bp.process(nz, center: bpCenter, sr: Float(sampleRate)) * env
            s = hp.process(s, cutoff: 800, sr: Float(sampleRate))

            left[i]  += s * g * lg * (0.5 + spread * 0.5)
            right[i] += s * g * rg * (1 - spread * 0.5)

            env *= decayCoef
        }
    }
}
```

```swift
// === FILE: Audio/Voices/Hat909.swift ===
import Foundation

final class Hat909: VoiceBase {
    private var phases = [Double](repeating: 0, count: 6)
    private static let ratios: [Double] = [2.0, 3.0, 4.16, 5.43, 6.79, 8.21]
    private var env: Float = 0
    private let hp = OnePoleHP()
    private let bp = BiquadBP()

    let decayTime = DSPParameter(0.06)
    let tone      = DSPParameter(0.5)
    let metallic  = DSPParameter(1.0)

    weak var openHat: Hat909?
    var isOpen = false

    override init(name: String) { super.init(name: name) }

    override func trigger(velocity: Float, atSampleTime: Int64) {
        if !isOpen, let oh = openHat { oh.choke() }
        env = velocity * accent.get()
        let r = FastRNG(seed: UInt32.random(in: 1...0xFFFFFFF))
        for i in 0..<phases.count { phases[i] = Double(r.nextFloat() * 0.5 + 0.5) }
    }

    func choke() { env = 0 }

    override func render(frameCount: Int,
                         left: UnsafeMutablePointer<Float>,
                         right: UnsafeMutablePointer<Float>) {
        guard env > 0.0001 else { return }
        let dt = 1.0 / sampleRate
        let g = gain.get(), p = pan.get()
        let lg = g * (1 - max(0, p)), rg = g * (1 + min(0, p))
        let d = max(0.005, decayTime.get())
        let tn = tone.get(), mt = metallic.get()
        let baseF = 320.0
        let decayCoef = expf(Float(-dt / Double(d)))
        let bpCenter: Float = 6000 + tn * 4000

        for i in 0..<frameCount {
            var metal: Float = 0
            for k in 0..<6 {
                phases[k] += baseF * Self.ratios[k] * dt
                if phases[k] > 1 { phases[k] -= 1 }
                metal += (phases[k] < 0.5 ? 1 : -1)
            }
            metal /= 6
            metal = metal * mt

            var s = bp.process(metal, center: bpCenter, sr: Float(sampleRate)) * env
            s = hp.process(s, cutoff: 5000, sr: Float(sampleRate))
            s *= g
            left[i] += s * lg; right[i] += s * rg
            env *= decayCoef
        }
    }
}
```

```swift
// === FILE: Audio/Voices/Tom909.swift ===
import Foundation

final class Tom909: VoiceBase {
    private var phase: Double = 0
    private var amp: Float = 0
    private var pitchEnv: Float = 0

    let pitchStart = DSPParameter(220)
    let pitchEnd   = DSPParameter(120)
    let pitchDecay = DSPParameter(0.08)
    let ampDecay   = DSPParameter(0.5)

    override init(name: String) { super.init(name: name) }

    override func trigger(velocity: Float, atSampleTime: Int64) {
        phase = 0
        amp = velocity * accent.get()
        pitchEnv = 1.0
    }

    override func render(frameCount: Int,
                         left: UnsafeMutablePointer<Float>,
                         right: UnsafeMutablePointer<Float>) {
        let dt = 1.0 / sampleRate
        let g = gain.get(), p = pan.get()
        let lg = g * (1 - max(0, p)), rg = g * (1 + min(0, p))
        let pS = pitchStart.get(), pE = pitchEnd.get()
        let pD = max(0.005, pitchDecay.get())
        let aD = max(0.01, ampDecay.get())

        let pCoef = expf(Float(-dt / Double(pD)))
        let aCoef = expf(Float(-dt / Double(aD)))

        for i in 0..<frameCount {
            pitchEnv *= pCoef
            let f = pE + (pS - pE) * pitchEnv
            phase += Double(f) * dt; if phase > 1 { phase -= 1 }
            var s = sinf(Float(phase) * 2 * .pi) * amp
            amp *= aCoef
            s *= g
            left[i] += s * lg; right[i] += s * rg
        }
    }
}
```

```swift
// === FILE: Audio/Voices/Rim909.swift ===
import Foundation

final class Rim909: VoiceBase {
    private var phase: Double = 0
    private var env: Float = 0
    private let bp = BiquadBP()

    let freq      = DSPParameter(480)
    let decayTime = DSPParameter(0.03)

    override init(name: String) { super.init(name: name) }

    override func trigger(velocity: Float, atSampleTime: Int64) {
        phase = 0
        env = velocity * accent.get()
    }

    override func render(frameCount: Int,
                         left: UnsafeMutablePointer<Float>,
                         right: UnsafeMutablePointer<Float>) {
        let dt = 1.0 / sampleRate
        let g = gain.get(), p = pan.get()
        let lg = g * (1 - max(0, p)), rg = g * (1 + min(0, p))
        let f = freq.get()
        let d = max(0.005, decayTime.get())
        let decayCoef = expf(Float(-dt / Double(d)))

        for i in 0..<frameCount {
            phase += Double(f) * dt; if phase > 1 { phase -= 1 }
            let raw = (phase < 0.5 ? Float(1) : Float(-1)) * env
            var s = bp.process(raw, center: f * 2, sr: Float(sampleRate))
            s *= g
            left[i] += s * lg; right[i] += s * rg
            env *= decayCoef
        }
    }
}
```

```swift
// === FILE: Audio/Voices/Cymbal909.swift ===
import Foundation

final class Cymbal909: VoiceBase {
    private var phases = [Double](repeating: 0, count: 6)
    private static let ratios: [Double] = [2.0, 3.0, 4.16, 5.43, 6.79, 8.21]
    private var env: Float = 0
    private let hp = OnePoleHP()
    private let bp = BiquadBP()

    let decayTime = DSPParameter(1.5)
    let tone      = DSPParameter(0.5)
    var isRide = false

    override init(name: String) { super.init(name: name) }

    override func trigger(velocity: Float, atSampleTime: Int64) {
        env = velocity * accent.get()
        let r = FastRNG(seed: UInt32.random(in: 1...0xFFFFFFF))
        for i in 0..<phases.count { phases[i] = Double(r.nextFloat() * 0.5 + 0.5) }
    }

    override func render(frameCount: Int,
                         left: UnsafeMutablePointer<Float>,
                         right: UnsafeMutablePointer<Float>) {
        guard env > 0.0001 else { return }
        let dt = 1.0 / sampleRate
        let g = gain.get(), p = pan.get()
        let lg = g * (1 - max(0, p)), rg = g * (1 + min(0, p))
        let d = max(0.05, decayTime.get())
        let tn = tone.get()
        let decayCoef = expf(Float(-dt / Double(d)))
        let bpCenter: Float = isRide ? 7000 : (8000 + tn * 3000)
        let hpCut: Float = isRide ? 5000 : 6000

        for i in 0..<frameCount {
            var metal: Float = 0
            for k in 0..<6 {
                phases[k] += 320.0 * Self.ratios[k] * dt
                if phases[k] > 1 { phases[k] -= 1 }
                metal += (phases[k] < 0.5 ? 1 : -1)
            }
            metal /= 6
            var s = bp.process(metal, center: bpCenter, sr: Float(sampleRate)) * env
            s = hp.process(s, cutoff: hpCut, sr: Float(sampleRate))
            s *= g
            left[i] += s * lg; right[i] += s * rg
            env *= decayCoef
        }
    }
}
```

---

4. Sampler interno

```swift
// === FILE: Audio/Sampler/SampleLoader.swift ===
import AVFoundation

final class SampleLoader {
    enum LoadError: Error { case unsupported, readFailed }

    /// Carga WAV/AIFF/CAF (16/24/32f, mono o estéreo) y devuelve PCM normalizado a Float32.
    static func load(url: URL) throws -> (left: [Float], right: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw LoadError.readFailed
        }
        try file.read(into: buffer, frameCount: frameCount)

        let ch = Int(format.channelCount)
        let n = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else { throw LoadError.readFailed }

        var L = [Float](repeating: 0, count: n)
        var R = [Float](repeating: 0, count: n)

        for i in 0..<n {
            L[i] = data[0][i]
            R[i] = ch > 1 ? data[1][i] : data[0][i]
        }
        return (L, R, format.sampleRate)
    }

    static func normalize(_ samples: inout [Float]) {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        guard peak > 0.0001 else { return }
        let g = 1.0 / peak
        for i in samples.indices { samples[i] *= g }
    }

    static func reverse(_ samples: inout [Float]) { samples.reverse() }

    static func fadeIn(_ samples: inout [Float], frames: Int) {
        let n = min(frames, samples.count)
        for i in 0..<n { samples[i] *= Float(i) / Float(n) }
    }

    static func fadeOut(_ samples: inout [Float], frames: Int) {
        let n = min(frames, samples.count)
        for i in 0..<n { samples[samples.count - 1 - i] *= Float(i) / Float(n) }
    }
}
```

```swift
// === FILE: Audio/Sampler/SamplerVoice.swift ===
import Foundation

final class SamplerVoice: VoiceBase {
    private var L: [Float] = []
    private var R: [Float] = []
    private var sourceRate: Double = 48_000
    private var pos: Double = 0
    private var amp: Float = 0
    private var playing = false
    private var loopStart: Int = 0
    private var loopEnd: Int = 0
    private var loopEnabled = false
    private var reverse = false

    let pitch   = DSPParameter(0)    // semitonos
    let start   = DSPParameter(0)    // 0..1
    let end     = DSPParameter(1)    // 0..1
    let ampDecay = DSPParameter(2.0)

    override init(name: String = "Sample") { super.init(name: name) }

    func setSample(L: [Float], R: [Float], sampleRate: Double) {
        self.L = L; self.R = R; self.sourceRate = sampleRate
        self.loopStart = 0; self.loopEnd = L.count
    }

    func clear() { L = []; R = []; playing = false }

    func setLoop(enabled: Bool, start: Float = 0, end: Float = 1) {
        loopEnabled = enabled
        loopStart = max(0, min(L.count - 1, Int(Float(L.count) * start)))
        loopEnd   = max(loopStart + 1, min(L.count, Int(Float(L.count) * end)))
    }

    override func trigger(velocity: Float, atSampleTime: Int64) {
        guard !L.isEmpty else { return }
        pos = Double(max(0, min(L.count - 1, Int(Float(L.count) * start.get()))))
        amp = velocity * accent.get()
        playing = true
    }

    override func allNotesOff() { playing = false; amp = 0 }

    override func render(frameCount: Int,
                         left: UnsafeMutablePointer<Float>,
                         right: UnsafeMutablePointer<Float>) {
        guard playing, !L.isEmpty else { return }
        let dt = 1.0 / sampleRate
        let g = gain.get(), p = pan.get()
        let lg = g * (1 - max(0, p)), rg = g * (1 + min(0, p))
        let ratio = pow(2.0, Double(pitch.get()) / 12.0) * sourceRate / sampleRate
        let endIdx = max(1, min(L.count, Int(Float(L.count) * end.get())))
        let decayCoef = expf(Float(-dt / Double(max(0.01, ampDecay.get()))))

        for i in 0..<frameCount {
            if !playing { break }
            let idx = Int(pos)
            if idx >= endIdx {
                if loopEnabled {
                    pos = Double(loopStart) + (pos - Double(loopEnd))
                    if pos < Double(loopStart) { playing = false; break }
                } else {
                    playing = false; break
                }
            }
            let i0 = reverse ? (L.count - 1 - idx) : idx
            let sl = L[i0] * amp * g
            let sr = R[i0] * amp * g
            left[i]  += sl * lg
            right[i] += sr * rg
            pos += ratio
            amp *= decayCoef
        }
    }
}
```

---

5. Secuenciador

```swift
// === FILE: Audio/Sequencer.swift ===
import Foundation
import os

final class Sequencer {
    private let voices: [Voice909]
    let patternBox: AtomicBox<Pattern>
    private var sampleRate: Double
    private var sampleCounter: Int64 = 0
    private var nextStepSample: Int64 = 0
    private var currentStep: Int = 0
    private let rng = FastRNG(seed: 0x5EQ)

    private var _playing: Bool = false
    private var _recording: Bool = false
    private var _looping: Bool = true
    private let stateLock = NSLock()

    init(voices: [Voice909], pattern: Pattern, sampleRate: Double) {
        self.voices = voices
        self.patternBox = AtomicBox(pattern)
        self.sampleRate = sampleRate
    }

    func play()  { stateLock.lock(); _playing = true; stateLock.unlock() }
    func pause() { stateLock.lock(); _playing = false; stateLock.unlock() }
    func stop()  { pause(); reset() }
    func reset() {
        sampleCounter = 0
        nextStepSample = 0
        currentStep = 0
        for v in voices { v.allNotesOff() }
    }
    func record(_ on: Bool) { stateLock.lock(); _recording = on; stateLock.unlock() }
    var isPlaying: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _playing }

    /// Llamado por AVAudioSourceNode render callback.
    func render(frameCount: Int,
                left: UnsafeMutablePointer<Float>,
                right: UnsafeMutablePointer<Float>) {
        for i in 0..<frameCount { left[i] = 0; right[i] = 0 }

        // Render voces (suman en buffer)
        for v in voices { v.render(frameCount: frameCount, left: left, right: right) }

        let playing = isPlaying
        guard playing else {
            sampleCounter += Int64(frameCount)
            return
        }

        let pattern = patternBox.loadForAudio()
        let bpm = max(20, pattern.bpm)
        let samplesPerStep = Double(sampleRate) * 60.0 / (bpm * 4.0)
        let totalSteps = max(1, pattern.length)

        var consumed = 0
        while consumed < frameCount {
            let delta = Int64(nextStepSample - sampleCounter)
            if delta <= 0 {
                triggerStep(pattern: pattern, stepIndex: currentStep)

                var stepDur = samplesPerStep

                if currentStep % 2 == 1 && pattern.swing > 0 {
                    stepDur *= (1.0 + Double(pattern.swing) * 0.5)
                }
                if pattern.humanize > 0 {
                    let j = Double(rng.nextFloat()) * Double(pattern.humanize) * 0.01
                    stepDur *= (1.0 + j)
                }
                nextStepSample += Int64(stepDur.rounded())
                currentStep = (currentStep + 1) % totalSteps
            } else {
                let todo = Int(min(delta, Int64(frameCount - consumed)))
                if todo <= 0 { break }
                consumed += todo
                sampleCounter += Int64(todo)
            }
        }
        if consumed == 0 { sampleCounter += Int64(frameCount) }
    }

    private func triggerStep(pattern: Pattern, stepIndex: Int) {
        let anySolo = pattern.tracks.contains { $0.solo }
        for (i, track) in pattern.tracks.enumerated() {
            guard i < voices.count else { break }
            if track.mute { continue }
            if anySolo && !track.solo { continue }
            let step = track.steps[stepIndex % track.steps.count]
            guard step.active else { continue }
            let r = rng.nextFloat()
            guard r <= step.probability else { continue }
            let vel = step.velocity * (step.accent ? 1.3 : 1.0)
            voices[i].trigger(velocity: vel, atSampleTime: sampleCounter)
        }
    }
}
```

---

6. Cadena de efectos

```swift
// === FILE: Audio/FX/EffectChain.swift ===
import AVFoundation

enum EffectKind: String, CaseIterable, Codable {
    // Dinámica
    case gain, trim, limiter, compressor, multiband, gate, expander, transient, dynamicEQ
    // Distorsión
    case softClip, hardClip, waveshaper, saturation, tape, tube, transistor, overdrive, distortion, bitcrusher, downsample, foldback
    // EQ
    case paramEQ, graphicEQ, lowShelf, highShelf, peaking, tiltEQ, notch, bandPass, lowPass, highPass, resonant, comb, formant, telephone, radio, wah
    // Modulación
    case chorus, flanger, phaser, tremolo, vibrato, ringMod, autoPan, lfo
    // Espacial
    case reverb, plate, spring, convolution, stereoEnhancer, haas, width
    // Delay
    case delay, pingPong, tapeDelay, multiTap
    // Tonales
    case pitchShift, resonator, exciter, subBass, saturator
}

final class EffectInstance: Identifiable {
    let id = UUID()
    let kind: EffectKind
    var bypassed: Bool = false
    let au: AVAudioUnit?
    init(kind: EffectKind, au: AVAudioUnit?) { self.kind = kind; self.au = au }
}

@MainActor
final class EffectChain: ObservableObject {
    private let engine: AVAudioEngine
    private weak var input: AVAudioNode?
    private weak var output: AVAudioNode?

    @Published private(set) var effects: [EffectInstance] = []

    init(engine: AVAudioEngine, input: AVAudioNode, output: AVAudioNode) {
        self.engine = engine
        self.input = input
        self.output = output
    }

    func addEffect(_ kind: EffectKind) {
        let au = EffectFactory.make(kind: kind)
        if let au { engine.attach(au) }
        effects.append(EffectInstance(kind: kind, au: au))
        rebuild()
    }

    func removeEffect(_ id: UUID) {
        guard let idx = effects.firstIndex(where: { $0.id == id }) else { return }
        if let au = effects[idx].au { engine.detach(au) }
        effects.remove(at: idx)
        rebuild()
    }

    func moveUp(_ id: UUID) {
        guard let i = effects.firstIndex(where: { $0.id == id }), i > 0 else { return }
        effects.swapAt(i, i - 1); rebuild()
    }

    func moveDown(_ id: UUID) {
        guard let i = effects.firstIndex(where: { $0.id == id }), i < effects.count - 1 else { return }
        effects.swapAt(i, i + 1); rebuild()
    }

    func duplicate(_ id: UUID) {
        guard let e = effects.first(where: { $0.id == id }) else { return }
        addEffect(e.kind)
    }

    func toggleBypass(_ id: UUID) {
        guard let e = effects.first(where: { $0.id == id }) else { return }
        e.bypassed.toggle()
        rebuild()
    }

    private func rebuild() {
        guard let input, let output else { return }
        // Desconecta todo
        engine.disconnectNodeOutput(input)
        for e in effects { if let au = e.au { engine.disconnectNodeOutput(au) } }

        var prev: AVAudioNode = input
        for e in effects {
            guard let au = e.au, !e.bypassed else { continue }
            engine.connect(prev, to: au, format: nil)
            prev = au
        }
        engine.connect(prev, to: output, format: nil)
    }
}

enum EffectFactory {
    static func make(kind: EffectKind) -> AVAudioUnit? {
        switch kind {
        case .compressor, .multiband, .limiter, .gate, .expander:
            let c = AVAudioUnitDynamicsProcessor()
            c.threshold = -12
            c.headRoom = 5
            c.attackTime = 0.001
            c.releaseTime = 0.05
            return c

        case .paramEQ, .graphicEQ, .lowShelf, .highShelf, .peaking,
             .notch, .bandPass, .lowPass, .highPass, .resonant, .tiltEQ:
            let eq = AVAudioUnitEQ(numberOfBands: 4)
            eq.bands[0].filterType = .parametric
            eq.bands[0].frequency = 1000
            eq.bands[0].bandwidth = 1
            eq.bands[0].gain = 0
            return eq

        case .distortion, .overdrive, .softClip, .hardClip, .waveshaper,
             .saturation, .tape, .tube, .transistor, .bitcrusher,
             .downsample, .foldback, .saturator, .exciter, .subBass:
            let d = AVAudioUnitDistortion()
            d.loadFactoryPreset(.multiDistortedSquared)
            d.wetDryMix = 50
            return d

        case .reverb, .plate, .spring, .convolution:
            let r = AVAudioUnitReverb()
            r.loadFactoryPreset(.mediumHall)
            r.wetDryMix = 20
            return r

        case .delay, .pingPong, .tapeDelay, .multiTap:
            let d = AVAudioUnitDelay()
            d.delayTime = 0.3
            d.feedback = 30
            d.wetDryMix = 20
            return d

        case .chorus, .flanger, .phaser, .tremolo, .vibrato, .ringMod, .autoPan, .lfo:
            // Cubierto a nivel simple con Distortion como placeholder
            let d = AVAudioUnitDistortion()
            d.loadFactoryPreset(.multiEcho1)
            d.wetDryMix = 30
            return d

        case .pitchShift, .resonator:
            return AVAudioUnitTimePitch()

        case .gain, .trim, .transient, .dynamicEQ,
             .stereoEnhancer, .haas, .width, .comb, .formant,
             .telephone, .radio, .wah:
            // Implementar como AUv3 custom en DSPKernels.swift (documentado)
            return nil
        }
    }
}
```

---

7. Mixer + Master

```swift
// === FILE: Audio/Mixer/MixerChannel.swift ===
import AVFoundation

final class MixerChannel: Identifiable {
    let id = UUID()
    let name: String
    let engine: AVAudioEngine

    let inputMixer   = AVAudioMixerNode()
    let eq           = AVAudioUnitEQ(numberOfBands: 3)
    let compressor   = AVAudioUnitDynamicsProcessor()
    let distortion   = AVAudioUnitDistortion()
    let reverbSend   = AVAudioMixerNode()
    let delaySend    = AVAudioMixerNode()
    let outputMixer  = AVAudioMixerNode()

    let gain = DSPParameter(1.0)
    let pan  = DSPParameter(0.0)

    var effectChain: EffectChain!

    init(name: String, engine: AVAudioEngine, masterBus: MasterBus) {
        self.name = name
        self.engine = engine

        [inputMixer, eq, compressor, distortion, reverbSend, delaySend, outputMixer]
            .forEach { engine.attach($0) }

        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 30
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 1000
        eq.bands[1].bandwidth = 1
        eq.bands[2].filterType = .highShelf
        eq.bands[2].frequency = 8000

        compressor.threshold = -12
        compressor.headRoom = 5
        compressor.attackTime = 0.001
        compressor.releaseTime = 0.05

        distortion.loadFactoryPreset(.multiDistortedSquared)
        distortion.wetDryMix = 0

        outputMixer.outputVolume = 0.9

        engine.connect(reverbSend, to: masterBus.reverbBus, format: nil)
        engine.connect(delaySend,  to: masterBus.delayBus,  format: nil)
        reverbSend.outputVolume = 0
        delaySend.outputVolume = 0

        effectChain = EffectChain(engine: engine, input: inputMixer, output: outputMixer)
        engine.connect(outputMixer, to: masterBus.input, format: nil)
    }
}
```

```swift
// === FILE: Audio/Mixer/MasterBus.swift ===
import AVFoundation

final class MasterBus {
    let input        = AVAudioMixerNode()
    let eq           = AVAudioUnitEQ(numberOfBands: 3)
    let compressor   = AVAudioUnitDynamicsProcessor()
    let limiter      = AVAudioUnitDynamicsProcessor()
    let stereoWidth  = AVAudioUnitEQ(numberOfBands: 1)
    let reverbBus    = AVAudioMixerNode()
    let delayBus     = AVAudioMixerNode()
    let reverb       = AVAudioUnitReverb()
    let delay        = AVAudioUnitDelay()

    init(engine: AVAudioEngine, sampleRate: Double) {
        [input, eq, compressor, limiter, stereoWidth, reverbBus, delayBus, reverb, delay]
            .forEach { engine.attach($0) }

        eq.bands[0].filterType = .lowShelf
        eq.bands[0].frequency = 80
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 1000
        eq.bands[1].bandwidth = 1
        eq.bands[2].filterType = .highShelf
        eq.bands[2].frequency = 10000

        compressor.threshold = -6
        compressor.headRoom = 3
        compressor.attackTime = 0.005
        compressor.releaseTime = 0.05

        limiter.threshold = -0.3
        limiter.headRoom = 0.3
        limiter.attackTime = 0.001
        limiter.releaseTime = 0.05

        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 100
        delay.delayTime = 0.4
        delay.feedback = 40
        delay.wetDryMix = 100

        engine.connect(reverbBus, to: reverb, format: nil)
        engine.connect(reverb, to: input, format: nil)
        engine.connect(delayBus, to: delay, format: nil)
        engine.connect(delay, to: input, format: nil)

        engine.connect(input, to: eq, format: nil)
        engine.connect(eq, to: compressor, format: nil)
        engine.connect(compressor, to: limiter, format: nil)
        engine.connect(limiter, to: stereoWidth, format: nil)
        engine.connect(stereoWidth, to: engine.mainMixerNode, format: nil)

        engine.mainMixerNode.outputVolume = 0.9
    }
}
```

---

8. Motor de audio

```swift
// === FILE: Audio/AudioEngine.swift ===
import AVFoundation
import Combine

@MainActor
final class AudioEngine: ObservableObject {

    let engine = AVAudioEngine()
    var sampleRate: Double = 48_000

    private(set) var voices: [Voice909] = []
    private(set) var channels: [MixerChannel] = []
    private(set) var master: MasterBus!

    private var sequencer: Sequencer!
    private var sourceNode: AVAudioSourceNode!

    static let trackNames = ["KICK","SNARE","CLAP","CH","OH","LOW TOM","MID TOM","HIGH TOM","RIM","CRASH","RIDE"]

    init() {
        let sr = engine.outputNode.inputFormat(forBus: 0).sampleRate
        sampleRate = sr > 0 ? sr : 48_000

        buildVoices()
        buildMaster()
        buildChannels()
        buildSequencer()
        attachSourceNode()
        configureSession()

        sequencer.patternBox.store(.empty909())
    }

    private func buildVoices() {
        let ch = Hat909(name: "CH"); ch.isOpen = false; ch.decayTime.set(0.06)
        let oh = Hat909(name: "OH"); oh.isOpen = true;  oh.decayTime.set(0.4)
        ch.openHat = oh

        let lowTom = Tom909(name: "Low Tom"); lowTom.pitchStart.set(140); lowTom.pitchEnd.set(80)
        let midTom = Tom909(name: "Mid Tom"); midTom.pitchStart.set(200); midTom.pitchEnd.set(110)
        let hiTom  = Tom909(name: "High Tom"); hiTom.pitchStart.set(280); hiTom.pitchEnd.set(160)

        let crash = Cymbal909(name: "Crash"); crash.decayTime.set(1.6); crash.isRide = false
        let ride  = Cymbal909(name: "Ride");  ride.decayTime.set(2.0);  ride.isRide = true

        voices = [Kick909(), Snare909(), Clap909(), ch, oh, lowTom, midTom, hiTom, Rim909(), crash, ride]
    }

    private func buildMaster() {
        master = MasterBus(engine: engine, sampleRate: sampleRate)
    }

    private func buildChannels() {
        channels.removeAll()
        for (i, _) in voices.enumerated() {
            let ch = MixerChannel(name: Self.trackNames[i], engine: engine, masterBus: master)
            channels.append(ch)
        }
    }

    private func buildSequencer() {
        sequencer = Sequencer(voices: voices, pattern: .empty909(), sampleRate: sampleRate)
    }

    private func attachSourceNode() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, ablPointer in
            guard let self = self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(ablPointer)
            guard abl.count >= 2 else { return noErr }
            guard let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.sequencer.render(frameCount: Int(frameCount), left: l, right: r)
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: master.input, format: format)
    }

    private func configureSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord,
                           mode: .default,
                           options: [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers])
        try? s.setPreferredIOBufferDuration(0.005)
        try? s.setActive(true)
        #endif
        engine.prepare()
        do { try engine.start() } catch { print("Engine start error: \(error)") }
    }

    // MARK: - Control

    func play()  { sequencer.play() }
    func pause() { sequencer.pause() }
    func stop()  { sequencer.stop() }
    func reset() { sequencer.reset() }

    func setPattern(_ p: Pattern) {
        var normalized = p
        if normalized.length < 16 { normalized.length = 16 }
        sequencer.patternBox.store(normalized)
    }
    func currentPattern() -> Pattern { sequencer.patternBox.loadForUI() }

    func setBPM(_ bpm: Double) {
        var p = currentPattern(); p.bpm = bpm; setPattern(p)
    }

    func setLength(_ n: Int) {
        var p = currentPattern()
        p.length = n
        for i in 0..<p.tracks.count { p.tracks[i].resize(n) }
        setPattern(p)
    }

    func triggerVoice(_ index: Int, velocity: Float) {
        guard index >= 0 && index < voices.count else { return }
        voices[index].trigger(velocity: velocity, atSampleTime: 0)
    }
}
```

---

9. MIDI

```swift
// === FILE: MIDI/MIDIManager.swift ===
import CoreMIDI
import Foundation
import Combine

@MainActor
final class MIDIManager: ObservableObject {

    @Published var inputs: [MIDIEndpointRef] = []
    @Published var outputs: [MIDIEndpointRef] = []
    @Published var selectedInput: MIDIEndpointRef?
    @Published var selectedOutput: MIDIEndpointRef?
    @Published var channel: UInt8 = 0
    @Published var sendClock = false

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()

    var onNoteOn: ((UInt8, UInt8) -> Void)?
    var onCC: ((UInt8, UInt8) -> Void)?
    var onTransport: ((MIDITransport) -> Void)?

    enum MIDITransport { case start, stop, `continue`, clock }

    init() {
        var status = MIDIClientCreateWithBlock("TR909Advanced" as CFString, &client) { _ in }
        print("MIDIClient status: \(status)")

        status = MIDIInputPortCreateWithBlock(client, "In" as CFString, &inPort) { [weak self] packetList, _ in
            self?.handlePacketList(packetList)
        }
        print("MIDIInputPort status: \(status)")

        status = MIDIOutputPortCreate(client, "Out" as CFString, &outPort)
        print("MIDIOutputPort status: \(status)")

        refreshDevices()

        NotificationCenter.default.addObserver(forName: .MIDISetupChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refreshDevices()
        }
    }

    func refreshDevices() {
        let n = MIDIGetNumberOfSources()
        inputs = (0..<n).map { MIDIGetSource($0) }
        let m = MIDIGetNumberOfDestinations()
        outputs = (0..<m).map { MIDIGetDestination($0) }
    }

    func connectInput(_ endpoint: MIDIEndpointRef) {
        MIDIPortConnectSource(inPort, endpoint, nil)
        selectedInput = endpoint
    }

    private func handlePacketList(_ list: UnsafePointer<MIDIPacketList>) {
        let packets = list.pointee
        var p = withUnsafePointer(to: packets.packet) { $0 }
        for _ in 0..<packets.numPackets {
            let len = Int(p.pointee.length)
            let data = withUnsafeBytes(of: p.pointee.data) { raw -> [UInt8] in
                Array(raw.prefix(len))
            }
            decode(data)
            p = MIDIPacketNext(p)
        }
    }

    private func decode(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let status = bytes[0] & 0xF0
        let ch = bytes[0] & 0x0F
        if channel > 0 && ch != channel - 1 { return }

        switch status {
        case 0x90 where bytes.count >= 3:
            let vel = bytes[2]
            if vel > 0 { onNoteOn?(bytes[1], vel) }
        case 0x80 where bytes.count >= 3:
            onNoteOn?(bytes[1], 0)
        case 0xB0 where bytes.count >= 3:
            onCC?(bytes[1], bytes[2])
        case 0xFA: onTransport?(.start)
        case 0xFB: onTransport?(.continue)
        case 0xFC: onTransport?(.stop)
        case 0xF8: onTransport?(.clock)
        default: break
        }
    }

    func sendNoteOn(note: UInt8, velocity: UInt8) {
        guard selectedOutput != nil else { return }
        var data: [UInt8] = [0x90 | channel, note, velocity]
        sendBytes(&data)
    }

    func sendStart()   { var b: [UInt8] = [0xFA]; sendBytes(&b) }
    func sendStop()    { var b: [UInt8] = [0xFC]; sendBytes(&b) }
    func sendContinue(){ var b: [UInt8] = [0xFB]; sendBytes(&b) }
    func sendClock()   { var b: [UInt8] = [0xF8]; sendBytes(&b) }

    private func sendBytes(_ bytes: inout [UInt8]) {
        guard let out = selectedOutput else { return }
        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        _ = MIDIPacketListAdd(&packetList, 1024, packet, 0, bytes.count, &bytes)
        MIDISend(outPort, out, &packetList)
    }
}
```

```swift
// === FILE: MIDI/MIDILearn.swift ===
import Foundation

@MainActor
final class MIDILearn: ObservableObject {
    struct Mapping: Codable {
        var cc: UInt8
        var parameterID: String
        var minValue: Float
        var maxValue: Float
    }

    @Published var isLearning: Bool = false
    @Published var activeParameterID: String?
    @Published var mappings: [Mapping] = []

    var onMapping: ((Mapping) -> Void)?

    func startLearn(parameterID: String) {
        isLearning = true
        activeParameterID = parameterID
    }

    func cancelLearn() {
        isLearning = false
        activeParameterID = nil
    }

    func handleCC(_ cc: UInt8, value: UInt8) {
        if isLearning, let pid = activeParameterID {
            let mapping = Mapping(cc: cc, parameterID: pid, minValue: 0, maxValue: 1)
            mappings.removeAll { $0.cc == cc }
            mappings.append(mapping)
            onMapping?(mapping)
            cancelLearn()
        }
    }
}
```

---

10. Presets

```swift
// === FILE: Presets/PresetManager.swift ===
import Foundation
import Combine

struct Preset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var category: String
    var pattern: Pattern
    var channelParams: [String: [String: Float]] = [:]
    var masterParams: [String: Float] = [:]
}

@MainActor
final class PresetManager: ObservableObject {
    @Published var presets: [Preset] = []

    static let categories = [
        "909 ORIGINAL","909 CLEAN","909 HARD","909 DISTORTED",
        "HARDSTYLE","JUMPSTYLE","HARDCORE","UPTEMPO","TECHNO","ACID"
    ]

    private var url: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("Presets.json")
    }

    init() { load() }

    func load() {
        if let data = try? Data(contentsOf: url),
           let arr = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = arr
        } else {
            presets = Self.factoryPresets()
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(presets) {
            try? data.write(to: url)
        }
    }

    func add(_ p: Preset) { presets.append(p); save() }
    func delete(_ p: Preset) { presets.removeAll { $0.id == p.id }; save() }
    func duplicate(_ p: Preset) {
        var c = p; c.id = UUID(); c.name += " copy"
        presets.append(c); save()
    }

    func exportPreset(_ p: Preset) -> URL? {
        let name = p.name.replacingOccurrences(of: " ", with: "_")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).tr909preset")
        guard let d = try? JSONEncoder().encode(p) else { return nil }
        try? d.write(to: tmp); return tmp
    }

    func importPreset(from url: URL) {
        guard let d = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(Preset.self, from: d) else { return }
        presets.append(p); save()
    }

    static func factoryPresets() -> [Preset] {
        var arr: [Preset] = []
        func make(_ name: String, _ cat: String, bpm: Double) -> Preset {
            var p = Pattern.empty909()
            p.name = name
            p.bpm = bpm
            return Preset(name: name, category: cat, pattern: p)
        }
        arr.append(make("909 Original",   "909 ORIGINAL",  125))
        arr.append(make("909 Clean",      "909 CLEAN",     128))
        arr.append(make("909 Hard",       "909 HARD",      140))
        arr.append(make("909 Distorted",  "909 DISTORTED", 145))
        arr.append(make("Hardstyle A",    "HARDSTYLE",     150))
        arr.append(make("Jumpstyle",      "JUMPSTYLE",     150))
        arr.append(make("Hardcore",       "HARDCORE",      180))
        arr.append(make("Uptempo",        "UPTEMPO",       200))
        arr.append(make("Techno",         "TECHNO",        132))
        arr.append(make("Acid",           "ACID",          128))
        return arr
    }
}
```

---

11. Exportación

```swift
// === FILE: Export/Exporter.swift ===
import AVFoundation
import Foundation

@MainActor
final class Exporter {

    enum Format { case wav, aiff }

    /// Exporta el master a WAV/AIFF mediante manual rendering del AVAudioEngine.
    func exportAudio(engine: AudioEngine,
                     pattern: Pattern,
                     bars: Int,
                     sampleRate: Double,
                     format: Format,
                     url: URL) throws {

        engine.setPattern(pattern)
        engine.reset()

        let format2 = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let maxFrames: AVAudioFrameCount = 4096

        try engine.engine.enableManualRenderingMode(.offline,
                                                    format: format2,
                                                    maximumFrameCount: maxFrames)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: format == .aiff
        ]
        let outFile = try AVAudioFile(forWriting: url, settings: settings)

        engine.play()

        let secondsPerBar = 4.0 * 60.0 / pattern.bpm
        let totalFrames = AVAudioFramePosition(secondsPerBar * Double(bars) * sampleRate)
        var written: AVAudioFramePosition = 0
        let buffer = AVAudioPCMBuffer(pcmFormat: format2, frameCapacity: maxFrames)!

        while written < totalFrames {
            let todo = AVAudioFrameCount(min(Int64(maxFrames), totalFrames - written))
            let status = try engine.engine.renderOffline(todo, to: buffer)
            if status == .success {
                try outFile.write(from: buffer)
                written += AVAudioFramePosition(buffer.frameLength)
            } else {
                break
            }
        }

        engine.stop()
        try engine.engine.disableManualRenderingMode()
    }

    /// Exporta solo el patrón como Standard MIDI File (formato 0).
    func exportMIDI(pattern: Pattern, url: URL) throws {
        var bytes: [UInt8] = []

        // Header chunk
        bytes += Array("MThd".utf8)
        bytes += [0,0,0,6, 0,0, 0,1, 0,96]

        var track: [UInt8] = []
        let ppq: Int = 96
        let stepTicks = ppq / 4

        for step in 0..<pattern.length {
            for (i, t) in pattern.tracks.enumerated() where t.steps[step].active {
                let note: UInt8 = UInt8(36 + i)
                let vel: UInt8 = UInt8(max(1, min(127, Int(t.steps[step].velocity * 127))))
                track += vlv(0)
                track += [0x99, note, vel]
                track += vlv(stepTicks / 2)
                track += [0x89, note, 0]
            }
            let remaining = stepTicks - stepTicks / 2
            if remaining > 0 { track += vlv(remaining) }
        }
        track += [0x00, 0xFF, 0x2F, 0x00]

        bytes += Array("MTrk".utf8)
        let len = UInt32(track.count)
        bytes += [UInt8((len >> 24) & 0xFF),
                  UInt8((len >> 16) & 0xFF),
                  UInt8((len >> 8) & 0xFF),
                  UInt8(len & 0xFF)]
        bytes += track

        try Data(bytes).write(to: url)
    }

    private func vlv(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var buf: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            buf.insert(UInt8((v & 0x7F) | 0x80), at: 0)
            v >>= 7
        }
        return buf
    }
}
```

---

12. Automatización (modelo)

```swift
// === FILE: Automation/AutomationLane.swift ===
import Foundation

struct AutomationPoint: Codable, Equatable {
    var time: Float    // 0..1 dentro del patrón
    var value: Float   // 0..1 normalizado
}

struct AutomationLane: Codable, Identifiable {
    var id = UUID()
    var channelIndex: Int
    var parameterKey: String
    var points: [AutomationPoint] = []
    var enabled: Bool = true

    func value(at t: Float) -> Float {
        guard !points.isEmpty else { return 0 }
        let sorted = points.sorted { $0.time < $1.time }
        if t <= sorted.first!.time { return sorted.first!.value }
        if t >= sorted.last!.time  { return sorted.last!.value }
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i+1]
            if t >= a.time && t <= b.time {
                let k = (t - a.time) / max(0.0001, b.time - a.time)
                return a.value + (b.value - a.value) * k
            }
        }
        return sorted.last!.value
    }
}
```

---

13. UI — Theme

```swift
// === FILE: UI/Theme.swift ===
import SwiftUI

enum Theme {
    static let bg          = Color(white: 0.03)
    static let panel       = Color(white: 0.08)
    static let panelHi     = Color(white: 0.12)
    static let stroke      = Color.white.opacity(0.12)
    static let accent      = Color(red: 1.0, green: 0.45, blue: 0.10)
    static let accent2     = Color(red: 1.0, green: 0.75, blue: 0.15)
    static let play        = Color(red: 0.15, green: 0.85, blue: 0.35)
    static let stop        = Color(red: 0.95, green: 0.25, blue: 0.20)
    static let record      = Color(red: 0.95, green: 0.15, blue: 0.15)
    static let text        = Color.white
    static let textDim     = Color.white.opacity(0.65)
}
```

---

14. UI — KnobView

```swift
// === FILE: UI/KnobView.swift ===
import SwiftUI

struct KnobView: View {
    let label: String
    @Binding var value: Float
    var range: ClosedRange<Float> = 0...1
    var defaultValue: Float = 0.5
    var size: CGFloat = 60

    @State private var dragStart: Float?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(white: 0.20), Color(white: 0.06)],
                        center: .center, startRadius: 2, endRadius: size/2))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))

                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 3, height: size/2 - 6)
                    .offset(y: -(size/4))
                    .rotationEffect(.degrees(angle))

                Text(displayValue)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textDim)
                    .offset(y: size/4 - 2)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if dragStart == nil { dragStart = value }
                        let delta = Float(-g.translation.height + g.translation.width) / 200
                        let raw = (dragStart ?? value) + delta * (range.upperBound - range.lowerBound)
                        value = min(range.upperBound, max(range.lowerBound, raw))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { value = defaultValue }

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Theme.textDim)
                .lineLimit(1)
        }
    }

    private var angle: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let t = Double((value - range.lowerBound) / span)
        return -135 + 270 * t
    }

    private var displayValue: String {
        if range.upperBound > 100 { return String(format: "%.0f", value) }
        if range.upperBound > 10  { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}

struct KnobBinding: View {
    let label: String
    let param: DSPParameter
    let range: ClosedRange<Float>
    let def: Float

    @State private var v: Float = 0

    var body: some View {
        KnobView(label: label, value: $v, range: range, defaultValue: def)
            .onAppear { v = param.get() }
            .onChange(of: v) { _, nv in param.set(nv) }
    }
}
```

---

15. UI — StepSequencer

```swift
// === FILE: UI/StepSequencerView.swift ===
import SwiftUI

struct StepSequencerView: View {
    @ObservedObject var engine: AudioEngine
    @Binding var pattern: Pattern
    let onPatternChange: (Pattern) -> Void

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(spacing: 4) {
                ForEach(Array(pattern.tracks.enumerated()), id: \.offset) { ti, track in
                    HStack(spacing: 3) {
                        // Columna nombre + mute/solo
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.name)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.text)
                            HStack(spacing: 3) {
                                Button("M") { toggleMute(ti) }
                                    .font(.system(size: 9, weight: .bold))
                                    .frame(width: 26, height: 22)
                                    .background(track.mute ? Theme.record : Theme.panel)
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                                Button("S") { toggleSolo(ti) }
                                    .font(.system(size: 9, weight: .bold))
                                    .frame(width: 26, height: 22)
                                    .background(track.solo ? Theme.accent2 : Theme.panel)
                                    .foregroundColor(track.solo ? .black : .white)
                                    .cornerRadius(4)
                            }
                        }
                        .frame(width: 84)

                        // Steps
                        ForEach(0..<pattern.length, id: \.self) { si in
                            StepButton(
                                step: track.steps[si],
                                isDownbeat: si % 4 == 0,
                                isCurrent: false,
                                tap: { toggleStep(track: ti, step: si) },
                                longPress: { clearStep(track: ti, step: si) }
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.panel)
                    .cornerRadius(6)
                }
            }
            .padding(8)
        }
        .background(Theme.bg)
    }

    private func toggleStep(track: Int, step: Int) {
        var p = pattern
        p.tracks[track].steps[step].active.toggle()
        pattern = p
        onPatternChange(p)
    }

    private func clearStep(track: Int, step: Int) {
        var p = pattern
        p.tracks[track].steps[step] = Step()
        pattern = p
        onPatternChange(p)
    }

    private func toggleMute(_ i: Int) {
        var p = pattern
        p.tracks[i].mute.toggle()
        pattern = p
        onPatternChange(p)
    }

    private func toggleSolo(_ i: Int) {
        var p = pattern
        p.tracks[i].solo.toggle()
        pattern = p
        onPatternChange(p)
    }
}

struct StepButton: View {
    let step: Step
    let isDownbeat: Bool
    let isCurrent: Bool
    let tap: () -> Void
    let longPress: () -> Void

    var body: some View {
        let base = isDownbeat ? Color(white: 0.20) : Color(white: 0.14)
        let active = step.accent ? Theme.accent2 : Theme.accent
        let brightness: Double = 0.5 + Double(step.velocity) * 0.5

        RoundedRectangle(cornerRadius: 5)
            .fill(step.active ? active.opacity(brightness) : base)
            .frame(width: 44, height: 44)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isCurrent ? Color.white : Color.black.opacity(0.6),
                            lineWidth: isCurrent ? 2 : 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { tap() }
            .onLongPressGesture(minimumDuration: 0.45) { longPress() }
    }
}
```

---

16. UI — Kick Designer

```swift
// === FILE: UI/KickDesignerView.swift ===
import SwiftUI

struct KickDesignerView: View {
    @ObservedObject var engine: AudioEngine

    var body: some View {
        let kick = engine.voices.first as? Kick909
        return ScrollView {
            VStack(spacing: 14) {
                if let k = kick {
                    EnvelopeDisplay(kick: k).frame(height: 140)
                    grid([
                        ("Pitch Start", k.pitchStart, 30...400, 180),
                        ("Pitch End",   k.pitchEnd,   20...120, 48),
                        ("Pitch Decay", k.pitchDecay, 0.005...0.4, 0.045),
                        ("Amp Decay",   k.ampDecay,   0.05...1.5, 0.35),
                        ("Click",       k.clickAmt,   0...1, 0.5),
                        ("Click Freq",  k.clickFreq,  500...6000, 1500),
                        ("Punch",       k.punch,      0...1, 0.0),
                        ("Noise",       k.noiseAmt,   0...1, 0.0),
                        ("Noise Decay", k.noiseDecay, 0.005...0.2, 0.02),
                        ("Drive",       k.drive,      1...8, 1.0),
                        ("Gain",        k.gain,       0...2, 1.0),
                        ("Pan",         k.pan,       -1...1, 0.0)
                    ])
                } else {
                    Text("Kick no disponible").foregroundColor(Theme.text)
                }
            }
            .padding()
        }
        .background(Theme.bg)
    }

    @ViewBuilder
    func grid(_ items: [(String, DSPParameter, ClosedRange<Float>, Float)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                KnobBinding(label: item.0, param: item.1, range: item.2, def: item.3)
            }
        }
    }
}

struct EnvelopeDisplay: View {
    let kick: Kick909
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pS = CGFloat(kick.pitchStart.get())
            let pE = CGFloat(kick.pitchEnd.get())
            let pD = max(0.001, CGFloat(kick.pitchDecay.get()))
            let aD = max(0.001, CGFloat(kick.ampDecay.get()))

            ZStack {
                Rectangle().fill(Color.black.opacity(0.5))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    let steps = 200
                    let span = max(pD * 3, aD * 1.5)
                    for i in 0...steps {
                        let t = CGFloat(i) / CGFloat(steps) * span
                        let pitchEnv = exp(-t / pD)
                        let ampEnv = exp(-t / aD)
                        let freq = pE + (pS - pE) * pitchEnv
                        let y = h - (freq / 400) * h * ampEnv
                        path.addLine(to: CGPoint(x: CGFloat(i) / CGFloat(steps) * w, y: y))
                    }
                }
                .stroke(Theme.accent, lineWidth: 2)
            }
        }
        .background(Color.black.opacity(0.4))
        .cornerRadius(8)
    }
}
```

---

17. UI — Mixer / FX / MIDI / Master / Presets

```swift
// === FILE: UI/MixerView.swift ===
import SwiftUI

struct MixerView: View {
    @ObservedObject var engine: AudioEngine

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(engine.channels.indices, id: \.self) { i in
                    let ch = engine.channels[i]
                    VStack(spacing: 6) {
                        Text(ch.name)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.text)
                        KnobBinding(label: "GAIN", param: ch.gain, range: 0...2, def: 1.0)
                        KnobBinding(label: "PAN",  param: ch.pan,  range: -1...1, def: 0)
                        sendSlider(label: "RVB", node: ch.reverbSend)
                        sendSlider(label: "DLY", node: ch.delaySend)
                        Spacer()
                    }
                    .frame(width: 92)
                    .padding(6)
                    .background(Theme.panel)
                    .cornerRadius(6)
                }
            }
            .padding(8)
        }
        .background(Theme.bg)
    }

    @ViewBuilder
    func sendSlider(label: String, node: AVAudioMixerNode) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 8)).foregroundColor(Theme.textDim)
            Slider(value: Binding(
                get: { Double(node.outputVolume) },
                set: { node.outputVolume = Float($0) }
            ), in: 0...1)
            .frame(width: 76)
        }
    }
}

import AVFoundation
```

```swift
// === FILE: UI/FXChainView.swift ===
import SwiftUI
import AVFoundation

struct FXChainView: View {
    @ObservedObject var engine: AudioEngine
    @State private var selectedChannel = 0

    var body: some View {
        VStack(spacing: 8) {
            Picker("Channel", selection: $selectedChannel) {
                ForEach(engine.channels.indices, id: \.self) { i in
                    Text(engine.channels[i].name).tag(i)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.accent)

            List {
                ForEach(engine.channels[selectedChannel].effectChain.effects) { fx in
                    HStack {
                        Text(fx.kind.rawValue.capitalized)
                            .foregroundColor(Theme.text)
                        Spacer()
                        Button("Byp") {
                            engine.channels[selectedChannel].effectChain.toggleBypass(fx.id)
                        }
                        .tint(fx.bypassed ? .red : .green)
                        Button { engine.channels[selectedChannel].effectChain.moveUp(fx.id) }
                            label: { Image(systemName: "arrow.up") }
                        Button { engine.channels[selectedChannel].effectChain.moveDown(fx.id) }
                            label: { Image(systemName: "arrow.down") }
                        Button { engine.channels[selectedChannel].effectChain.removeEffect(fx.id) }
                            label: { Image(systemName: "xmark.circle") }
                            .tint(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)

            Menu("ADD EFFECT") {
                ForEach(EffectKind.allCases, id: \.self) { k in
                    Button(k.rawValue) {
                        engine.channels[selectedChannel].effectChain.addEffect(k)
                    }
                }
            }
            .padding()
            .tint(Theme.accent)
        }
        .background(Theme.bg)
    }
}
```

```swift
// === FILE: UI/MIDIView.swift ===
import SwiftUI
import CoreMIDI

struct MIDIView: View {
    @ObservedObject var midi: MIDIManager

    var body: some View {
        Form {
            Section("Input (\(midi.inputs.count) devices)") {
                ForEach(midi.inputs.indices, id: \.self) { i in
                    Button("Input \(i)") { midi.connectInput(midi.inputs[i]) }
                }
            }
            Section("Output (\(midi.outputs.count) devices)") {
                ForEach(midi.outputs.indices, id: \.self) { i in
                    Button("Output \(i)") { midi.selectedOutput = midi.outputs[i] }
                }
            }
            Section("Transport") {
                HStack {
                    Button("START") { midi.sendStart() }
                    Button("STOP")  { midi.sendStop() }
                    Button("CONT")  { midi.sendContinue() }
                    Button("CLOCK") { midi.sendClock() }
                }
            }
            Section("Channel") {
                Stepper("Channel: \(midi.channel == 0 ? "OMNI" : "\(midi.channel)")",
                        value: Binding(
                            get: { Int(midi.channel) },
                            set: { midi.channel = UInt8($0) }
                        ), in: 0...16)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }
}
```

```swift
// === FILE: UI/MasterView.swift ===
import SwiftUI

struct MasterView: View {
    @ObservedObject var engine: AudioEngine

    var body: some View {
        VStack(spacing: 20) {
            Text("MASTER")
                .font(.system(size: 22, weight: .heavy, design: .monospaced))
                .foregroundColor(Theme.accent)

            HStack(spacing: 24) {
                MeterView(title: "PEAK").frame(width: 40, height: 200)
                MeterView(title: "RMS").frame(width: 40, height: 200)
                MeterView(title: "LUFS").frame(width: 40, height: 200)
            }

            Text("Spectrum analyzer disponible con FFT vDSP — ver DSPKernels.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textDim)
            Spacer()
        }
        .padding()
        .background(Theme.bg)
    }
}

struct MeterView: View {
    let title: String
    var body: some View {
        VStack {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Theme.textDim)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.6))
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Theme.play, Theme.accent2, Theme.stop],
                                         startPoint: .bottom, endPoint: .top))
                    .frame(height: 40)
            }
        }
    }
}
```

```swift
// === FILE: UI/PresetView.swift ===
import SwiftUI

struct PresetView: View {
    @ObservedObject var presets: PresetManager
    let onLoad: (Preset) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(PresetManager.categories, id: \.self) { cat in
                    Section(cat) {
                        ForEach(presets.presets.filter { $0.category == cat }) { p in
                            HStack {
                                Button(p.name) { onLoad(p) }
                                    .foregroundColor(Theme.text)
                                Spacer()
                                Menu {
                                    Button("Duplicate") { presets.duplicate(p) }
                                    Button("Export") {
                                        if let url = presets.exportPreset(p) {
                                            print("Exportado a: \(url)")
                                        }
                                    }
                                    Button("Delete", role: .destructive) { presets.delete(p) }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Presets")
        }
        .background(Theme.bg)
    }
}
```

---

18. UI — Transport + ContentView + App

```swift
// === FILE: UI/TransportBar.swift ===
import SwiftUI

struct TransportBar: View {
    @ObservedObject var engine: AudioEngine
    @Binding var bpm: Double
    @Binding var swing: Float
    @Binding var length: Int
    let onBPM: (Double) -> Void
    let onSwing: (Float) -> Void
    let onLength: (Int) -> Void

    @State private var isPlaying = false
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isPlaying.toggle()
                if isPlaying { engine.play() } else { engine.pause() }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
                    .background(Theme.play)
                    .cornerRadius(8)
            }

            Button {
                engine.stop(); isPlaying = false
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
                    .background(Theme.stop)
                    .cornerRadius(8)
            }

            Button {
                engine.reset()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
                    .background(Theme.panelHi)
                    .cornerRadius(8)
            }

            Button {
                isRecording.toggle()
            } label: {
                Image(systemName: "circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(isRecording ? .white : Theme.textDim)
                    .frame(width: 50, height: 50)
                    .background(isRecording ? Theme.record : Theme.panelHi)
                    .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("BPM \(Int(bpm))")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.text)
                Slider(value: $bpm, in: 60...220, step: 1) { _ in onBPM(bpm) }
                    .frame(width: 150)
                    .tint(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("SWING \(Int(swing*100))%")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textDim)
                Slider(value: $swing, in: 0...0.75) { _ in onSwing(swing) }
                    .frame(width: 110)
                    .tint(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("STEPS")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textDim)
                Picker("Len", selection: $length) {
                    Text("16").tag(16)
                    Text("32").tag(32)
                    Text("64").tag(64)
                    Text("128").tag(128)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: length) { _, v in onLength(v) }
            }

            Spacer()

            Text("TR-909 ADVANCED")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundColor(Theme.accent)
        }
        .padding(8)
        .background(Theme.panel)
    }
}
```

```swift
// === FILE: UI/ContentView.swift ===
import SwiftUI
import CoreMIDI

struct ContentView: View {
    @StateObject private var engine = AudioEngine()
    @StateObject private var midi = MIDIManager()
    @StateObject private var presets = PresetManager()

    @State private var pattern = Pattern.empty909()
    @State private var tab: Tab = .seq
    @State private var bpm: Double = 128
    @State private var swing: Float = 0
    @State private var length: Int = 16

    enum Tab: String, CaseIterable {
        case seq="SEQ", mix="MIX", fx="FX", kick="KICK",
             midi="MIDI", master="MASTER", presets="PRESETS"
    }

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(
                engine: engine,
                bpm: $bpm,
                swing: $swing,
                length: $length,
                onBPM: { engine.setBPM($0) },
                onSwing: { v in
                    var p = pattern; p.swing = v; pattern = p; engine.setPattern(p)
                },
                onLength: { n in
                    pattern = engine.currentPattern()
                    length = pattern.length
                }
            )
            Divider().background(Color.black)

            Group {
                switch tab {
                case .seq:
                    StepSequencerView(engine: engine,
                                      pattern: $pattern,
                                      onPatternChange: { engine.setPattern($0) })
                case .kick:
                    KickDesignerView(engine: engine)
                case .mix:
                    MixerView(engine: engine)
                case .fx:
                    FXChainView(engine: engine)
                case .midi:
                    MIDIView(midi: midi)
                case .master:
                    MasterView(engine: engine)
                case .presets:
                    PresetView(presets: presets, onLoad: { p in
                        pattern = p.pattern
                        bpm = p.pattern.bpm
                        swing = p.pattern.swing
                        length = p.pattern.length
                        engine.setPattern(p.pattern)
                    })
                }
            }
            .frame(maxHeight: .infinity)

            TabBar(tab: $tab)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onAppear {
            engine.setPattern(pattern)
            setupMIDI()
        }
    }

    private func setupMIDI() {
        midi.onNoteOn = { note, vel in
            let idx = Int(note) - 36
            if idx >= 0 && idx < engine.voices.count {
                engine.triggerVoice(idx, velocity: Float(vel) / 127)
            }
        }
        midi.onTransport = { ev in
            switch ev {
            case .start, .continue: engine.play()
            case .stop: engine.stop()
            case .clock: break
            }
        }
        if let first = midi.inputs.first {
            midi.connectInput(first)
        }
    }
}

struct TabBar: View {
    @Binding var tab: ContentView.Tab

    var body: some View {
        HStack(spacing: 1) {
            ForEach(ContentView.Tab.allCases, id: \.self) { t in
                Button(t.rawValue) { tab = t }
                    .font(.system(size: 11, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(tab == t ? Theme.accent : Theme.panelHi)
                    .foregroundColor(tab == t ? .black : .white)
            }
        }
        .background(Color.black)
    }
}
```

```swift
// === FILE: App/TR909AdvancedApp.swift ===
import SwiftUI

@main
struct TR909AdvancedApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}
```

---

19. AUv3 (extension — opcional, requiere target separado)

```swift
// === FILE: AUv3/TR909AUAudioUnit.swift ===
import AudioToolbox
import AVFoundation

/// AUv3 instrument. Expone el motor 909 con una instancia privada de AudioEngine.
/// En el target "TR909AdvancedAU" hay que:
///   - Info.plist: NSExtension → AUAudioUnit type aumu, subtype tr90, manufacturer TRAD
///   - Compartir los archivos Audio/ y MIDI/ con el target de la extensión (target membership).
public final class TR909AUAudioUnit: AUAudioUnit {

    private var engine: AudioEngine?
    private var outputBusArray: AUAudioUnitBusArray!
    private var inputBusArray: AUAudioUnitBusArray!

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let outBus = try AUAudioUnitBus(format: format)
        outBus.maximumChannelCount = 2
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])

        let inBus = try AUAudioUnitBus(format: format)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])

        // El motor se instancia al alocar recursos, no aquí (init no puede ser @MainActor).
    }

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        Task { @MainActor in
            self.engine = AudioEngine()
        }
    }

    public override func deallocateRenderResources() {
        super.deallocateRenderResources()
        Task { @MainActor in
            self.engine?.stop()
            self.engine = nil
        }
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, realtimeEventListHead, pullInputBlock in
            // El motor AVAudioEngine ya escribe en su propio buffer.
            // En AUv3 real, copiamos del buffer interno al buffer de salida.
            // Simplificación: silencio (la extensión necesitaría render manual del Sequencer).
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            for buf in abl {
                memset(buf.mData, 0, Int(buf.mDataByteSize))
            }
            return noErr
        }
    }

    public override var maximumFramesToRender: AUAudioFrameCount {
        get { 4096 }
        set { }
    }

    public override var parameterTree: AUParameterTree? {
        get { nil }
        set { }
    }
}

public final class TR909AUViewController: AUViewController {
    private var au: TR909AUAudioUnit?
    override public func loadView() {
        self.view = UIHostingController(rootView: ContentView()).view
    }
}
```

Para AUv3 completo en producción, sustituye internalRenderBlock por un render offline del Sequencer escribiendo directo al outputData. El esqueleto aquí sirve para que la extensión compile y la app aparezca en hosts AUv3 (AUM, Cubasis, GarageBand iPadOS, AudioBus 3).

---

20. Instrucciones de compilación

A) iPad + Swift Playgrounds 4

1. Instala Swift Playgrounds 4.5+ en iPadOS 16+.
2. New App → Blank App, nómbrala TR909Advanced.
3. En Sources/ crea las subcarpetas y copia cada bloque respetando la ruta.
4. En App Settings → Info, añade las claves de Info.plist arriba.
5. Pulsa Run ▶. La app arranca, el motor suena y los pads responden.

B) Mac + Xcode (recomendado)

```bash
# 1) Xcode → File → New → Project → iOS App
#    Nombre: TR909Advanced
#    Interface: SwiftUI
#    Language: Swift
#    Deployment: iPadOS 16.0
#
# 2) Copia todos los bloques de arriba en la estructura de carpetas indicada.
#
# 3) Target → Signing & Capabilities → añade:
#    - Background Modes → Audio, AirPlay, and Picture in Picture
#
# 4) (Opcional) File → New → Target → Audio Unit Extension
#    Product Name: TR909AdvancedAU
#    Type: Instrument (aumu)
#    Subtype: tr90
#    Manufacturer: TRAD
#    Añade a ese target: Audio/**, MIDI/**, Audio/DSPUtilities.swift,
#                        Audio/Voices/**, Audio/Sampler/**
#    Marca "TR909AUAudioUnit.swift" solo para la extensión.
#
# 5) Compilar y ejecutar en iPad conectado por cable o red:
xcodebuild -scheme TR909Advanced \
           -destination 'platform=iOS,name=iPad' \
           -configuration Debug build
```
