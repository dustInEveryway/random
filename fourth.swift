import UIKit

protocol TrackViewDelegate: AnyObject {
    func trackView(_ view: TrackView, didTapStep step: Int)
    func trackViewDidTapImport(_ view: TrackView)
    func trackViewDidTapMute(_ view: TrackView)
    func trackViewDidTapDelete(_ view: TrackView)
    func trackView(_ view: TrackView, didChangeVolume volume: Float)
}

class TrackView: UIView {

    weak var delegate: TrackViewDelegate?
    private(set) var trackIndex: Int
    private var track: Track
    private let stepsCount: Int
    private var stepButtons: [UIButton] = []
    private let nameLabel = UILabel()
    private let importButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let volumeSlider = UISlider()

    init(track: Track, trackIndex: Int, steps: Int) {
        self.track = track
        self.trackIndex = trackIndex
        self.stepsCount = steps
        super.init(frame: .zero)
        setupUI()
        refresh()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) no ha sido implementado")
    }

    private func setupUI() {
        nameLabel.frame = CGRect(x: 4, y: 4, width: 100, height: 16)
        nameLabel.font = UIFont.systemFont(ofSize: 11)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        importButton.frame = CGRect(x: 4, y: 22, width: 24, height: 24)
        importButton.setTitle("📂", for: .normal)
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        addSubview(importButton)

        muteButton.frame = CGRect(x: 30, y: 22, width: 24, height: 24)
        muteButton.setTitle("🔊", for: .normal)
        muteButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)
        addSubview(muteButton)

        deleteButton.frame = CGRect(x: 56, y: 22, width: 24, height: 24)
        deleteButton.setTitle("🗑", for: .normal)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        addSubview(deleteButton)

        volumeSlider.frame = CGRect(x: 4, y: 48, width: 100, height: 12)
        volumeSlider.minimumValue = 0
        volumeSlider.maximumValue = 1
        volumeSlider.value = track.volume
        volumeSlider.addTarget(self, action: #selector(volumeChanged), for: .valueChanged)
        addSubview(volumeSlider)

        let stepStartX: CGFloat = 108
        let stepWidth: CGFloat = 20
        let stepSpacing: CGFloat = 2
        for i in 0..<stepsCount {
            let button = UIButton(type: .custom)
            button.frame = CGRect(x: stepStartX + CGFloat(i) * (stepWidth + stepSpacing), y: 8, width: stepWidth, height: 40)
            button.layer.cornerRadius = 4
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor.lightGray.cgColor
            button.tag = i
            button.addTarget(self, action: #selector(stepTapped(_:)), for: .touchUpInside)
            addSubview(button)
            stepButtons.append(button)
        }

        let totalWidth = stepStartX + CGFloat(stepsCount) * (stepWidth + stepSpacing)
        self.frame.size.width = totalWidth
    }

    func refresh() {
        nameLabel.text = track.name
        muteButton.setTitle(track.isMuted ? "🔇" : "🔊", for: .normal)
        volumeSlider.value = track.volume
        for (i, button) in stepButtons.enumerated() {
            let isActive = track.steps[i]
            button.backgroundColor = isActive ? track.color : UIColor(white: 0.9, alpha: 1)
            button.layer.borderColor = isActive ? track.color.cgColor : UIColor.lightGray.cgColor
        }
    }

    func updateCurrentStep(_ step: Int) {
        for (i, button) in stepButtons.enumerated() {
            if i == step {
                button.layer.borderWidth = 2
                button.layer.borderColor = UIColor.blue.cgColor
            } else {
                button.layer.borderWidth = 1
                button.layer.borderColor = track.steps[i] ? track.color.cgColor : UIColor.lightGray.cgColor
            }
        }
    }

    @objc private func stepTapped(_ sender: UIButton) {
        delegate?.trackView(self, didTapStep: sender.tag)
    }

    @objc private func importTapped() {
        delegate?.trackViewDidTapImport(self)
    }

    @objc private func muteTapped() {
        delegate?.trackViewDidTapMute(self)
    }

    @objc private func deleteTapped() {
        delegate?.trackViewDidTapDelete(self)
    }

    @objc private func volumeChanged() {
        delegate?.trackView(self, didChangeVolume: volumeSlider.value)
    }
}