import UIKit

struct Track {
    let id = UUID().uuidString
    var name: String
    var url: URL?
    var isMuted = false
    var volume: Float = 0.9
    var steps: [Bool] = Array(repeating: false, count: 16)
    var color: UIColor

    var hasAudio: Bool { url != nil }
}