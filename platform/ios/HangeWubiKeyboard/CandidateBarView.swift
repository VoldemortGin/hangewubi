import UIKit

protocol CandidateBarViewDelegate: AnyObject {
    func candidateBarView(_ view: CandidateBarView, didSelectCandidateAt index: Int)
}

/// 候选条：左边显示当前编码（preedit），右边水平滚动显示候选词
class CandidateBarView: UIView {

    weak var delegate: CandidateBarViewDelegate?

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let preeditLabel = UILabel()
    private let separatorView = UIView()

    private(set) var candidates: [(text: String, code: String)] = []

    // 复用池：候选按钮与分隔线只创建一次，逐键只更新内容与显隐，避免每键全量重建视图与约束。
    private var buttonPool: [UIButton] = []
    private var separatorPool: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        backgroundColor = Self.barBackground

        separatorView.backgroundColor = .separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separatorView)

        preeditLabel.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        preeditLabel.textColor = .systemBlue
        preeditLabel.translatesAutoresizingMaskIntoConstraints = false
        preeditLabel.setContentHuggingPriority(.required, for: .horizontal)
        preeditLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(preeditLabel)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        addSubview(scrollView)

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
        preeditLabel.text = text.uppercased()
        preeditLabel.isHidden = text.isEmpty
    }

    func updateCandidates(_ newCandidates: [(text: String, code: String)]) {
        candidates = newCandidates
        let count = newCandidates.count

        // 从栈中移出全部已排列视图（保留视图与其约束，仅解除排列关系），随后按序复用重排。
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.isHidden = true
        }

        for (index, candidate) in newCandidates.enumerated() {
            // 候选项 = 序号 + 候选词
            let button = dequeueButton(at: index)
            configureButton(button, index: index, text: candidate.text)
            button.isHidden = false
            stackView.addArrangedSubview(button)

            // 分隔线（除最后一项）
            if index < count - 1 {
                let sep = dequeueSeparator(at: index)
                sep.isHidden = false
                stackView.addArrangedSubview(sep)
            }
        }

        scrollView.setContentOffset(.zero, animated: false)
        isHidden = newCandidates.isEmpty && (preeditLabel.text ?? "").isEmpty
    }

    /// 取复用池中第 index 个候选按钮，不足则新建一次并入池。
    private func dequeueButton(at index: Int) -> UIButton {
        if index < buttonPool.count { return buttonPool[index] }
        let button = UIButton(configuration: .plain())
        button.addTarget(self, action: #selector(candidateTapped(_:)), for: .touchUpInside)
        buttonPool.append(button)
        return button
    }

    /// 取复用池中第 index 个分隔线，不足则新建一次（含内部约束）并入池。
    private func dequeueSeparator(at index: Int) -> UIView {
        if index < separatorPool.count { return separatorPool[index] }
        let sep = UIView()
        sep.backgroundColor = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: 0.5).isActive = true

        let wrapper = UIView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(sep)
        NSLayoutConstraint.activate([
            sep.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            sep.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            sep.heightAnchor.constraint(equalTo: wrapper.heightAnchor, multiplier: 0.45),
            wrapper.widthAnchor.constraint(equalToConstant: 1),
        ])
        separatorPool.append(wrapper)
        return wrapper
    }

    /// 逐键只更新按钮内容与序号（视觉与原实现一致）。
    private func configureButton(_ button: UIButton, index: Int, text: String) {
        let isFirst = index == 0
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        config.background.backgroundColor = .clear

        // 富文本：序号小一号灰色，候选词正常
        let numberAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel,
            .baselineOffset: 2,
        ]
        let textAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: isFirst ? .semibold : .regular),
            .foregroundColor: isFirst ? UIColor.systemBlue : UIColor.label,
        ]
        let attr = NSMutableAttributedString(string: "\(index + 1) ", attributes: numberAttr)
        attr.append(NSAttributedString(string: text, attributes: textAttr))
        config.attributedTitle = AttributedString(attr)

        button.configuration = config
        button.tag = index
    }

    func clear() {
        updatePreedit("")
        updateCandidates([])
        isHidden = true
    }

    @objc private func candidateTapped(_ sender: UIButton) {
        delegate?.candidateBarView(self, didSelectCandidateAt: sender.tag)
    }

    private static let barBackground: UIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1.0)
            : UIColor(red: 0.94, green: 0.94, blue: 0.96, alpha: 1.0)
    }
}
