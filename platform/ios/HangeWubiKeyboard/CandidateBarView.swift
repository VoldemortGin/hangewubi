import UIKit

protocol CandidateBarViewDelegate: AnyObject {
    func candidateBarView(_ view: CandidateBarView, didSelectCandidateAt index: Int)
}

class CandidateBarView: UIView {

    weak var delegate: CandidateBarViewDelegate?

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let preeditLabel = UILabel()
    private let separatorView = UIView()

    private(set) var candidates: [(text: String, code: String)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        backgroundColor = .systemBackground

        // Bottom separator line
        separatorView.backgroundColor = .separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separatorView)

        // Preedit label (shows current input buffer)
        preeditLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        preeditLabel.textColor = .systemBlue
        preeditLabel.translatesAutoresizingMaskIntoConstraints = false
        preeditLabel.setContentHuggingPriority(.required, for: .horizontal)
        preeditLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(preeditLabel)

        // Scroll view for candidates
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Stack view inside scroll view
        stackView.axis = .horizontal
        stackView.spacing = 0
        stackView.alignment = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 0.5),

            preeditLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            preeditLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: preeditLabel.trailingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separatorView.topAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    func updatePreedit(_ text: String) {
        preeditLabel.text = text
        preeditLabel.isHidden = text.isEmpty
    }

    func updateCandidates(_ newCandidates: [(text: String, code: String)]) {
        candidates = newCandidates

        // Remove old buttons
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (index, candidate) in newCandidates.enumerated() {
            let numberPrefix = "\(index + 1). "
            let title = numberPrefix + candidate.text

            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
            if index == 0 {
                config.baseForegroundColor = .systemBlue
            } else {
                config.baseForegroundColor = .label
            }
            let font = index == 0
                ? UIFont.systemFont(ofSize: 16, weight: .semibold)
                : UIFont.systemFont(ofSize: 16)
            config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: font]))

            let button = UIButton(configuration: config)
            button.tag = index
            button.addTarget(self, action: #selector(candidateTapped(_:)), for: .touchUpInside)

            stackView.addArrangedSubview(button)
        }

        // Scroll back to start
        scrollView.setContentOffset(.zero, animated: false)

        isHidden = newCandidates.isEmpty && (preeditLabel.text ?? "").isEmpty
    }

    func clear() {
        updatePreedit("")
        updateCandidates([])
        isHidden = true
    }

    @objc private func candidateTapped(_ sender: UIButton) {
        delegate?.candidateBarView(self, didSelectCandidateAt: sender.tag)
    }
}
