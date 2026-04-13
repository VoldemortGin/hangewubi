import UIKit

protocol KeyboardViewDelegate: AnyObject {
    func keyboardView(_ view: KeyboardView, didTapKey key: String)
    func keyboardViewDidTapBackspace(_ view: KeyboardView)
    func keyboardViewDidTapSpace(_ view: KeyboardView)
    func keyboardViewDidTapReturn(_ view: KeyboardView)
    func keyboardViewDidTapGlobe(_ view: KeyboardView)
    func keyboardViewDidTapShift(_ view: KeyboardView)
    func keyboardViewDidTapModeSwitch(_ view: KeyboardView)
}

/// iOS 系统风格键盘视图，布局按屏幕宽度等比缩放
class KeyboardView: UIView {

    weak var delegate: KeyboardViewDelegate?

    private var keyButtons: [KeyButton] = []
    private var modeToggleButton: KeyButton?
    private var deleteButton: KeyButton?
    private var deleteTimer: Timer?
    private var deleteRepeatStarted = false

    var isEnglishMode = false {
        didSet { updateModeToggleAppearance() }
    }

    private(set) var isNumberMode = false

    var showGlobeKey: Bool = true {
        didSet {
            if oldValue != showGlobeKey { buildKeys() }
        }
    }

    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    // MARK: - Layouts

    private let letterRows: [[String]] = [
        ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"],
        ["A", "S", "D", "F", "G", "H", "J", "K", "L"],
        ["Z", "X", "C", "V", "B", "N", "M"],
    ]

    private let numberRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "¥", "&", "@", "\""],
        [".", ",", "?", "!", "'"],
    ]

    // MARK: - 等比计算的布局参数

    private var keySpacing: CGFloat { isIPad ? 8 : 6 }
    private var rowSpacing: CGFloat { isIPad ? 12 : 11 }
    private var edgeInset: CGFloat { isIPad ? 6 : 3 }
    private var keyCornerRadius: CGFloat { isIPad ? 6 : 5 }

    /// 可用宽度（减去两侧边距）
    private var availableWidth: CGFloat {
        let w = UIScreen.main.bounds.width
        return w - 2 * edgeInset
    }

    /// 第一排字母键宽度（10 键 + 9 间距平分）
    private var letterKeyWidth: CGFloat {
        (availableWidth - 9 * keySpacing) / 10
    }

    /// 第二排两侧缩进（让 9 键等宽并居中于 10 键行）
    private var row2SidePadding: CGFloat {
        (letterKeyWidth + keySpacing) / 2
    }

    /// 第三排功能键宽度（Shift/Delete 占据字母键以外的剩余空间）
    private var functionalKeyWidth: CGFloat {
        let rows = isNumberMode ? numberRows : letterRows
        let letterCount = CGFloat(rows[2].count)
        let lettersWidth = letterCount * letterKeyWidth + (letterCount - 1) * keySpacing
        return (availableWidth - lettersWidth - 2 * keySpacing) / 2
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupKeyboard()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupKeyboard()
    }

    private func setupKeyboard() {
        backgroundColor = Self.keyboardBackgroundColor
        buildKeys()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
    }

    // MARK: - Build

    private func buildKeys() {
        subviews.forEach { $0.removeFromSuperview() }
        keyButtons.removeAll()
        modeToggleButton = nil
        deleteButton = nil

        let rows = isNumberMode ? numberRows : letterRows

        let containerStack = UIStackView()
        containerStack.axis = .vertical
        containerStack.spacing = rowSpacing
        containerStack.alignment = .fill
        containerStack.distribution = .fillEqually
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerStack)

        for (rowIndex, row) in rows.enumerated() {
            // 第二排：两侧等比缩进
            if rowIndex == 1 {
                let wrapper = makeRowStack()
                wrapper.distribution = .fill
                let rowStack = makeRowStack()

                let leftSpacer = UIView()
                leftSpacer.translatesAutoresizingMaskIntoConstraints = false
                leftSpacer.widthAnchor.constraint(equalToConstant: row2SidePadding).isActive = true
                let rightSpacer = UIView()
                rightSpacer.translatesAutoresizingMaskIntoConstraints = false
                rightSpacer.widthAnchor.constraint(equalToConstant: row2SidePadding).isActive = true

                wrapper.addArrangedSubview(leftSpacer)
                wrapper.addArrangedSubview(rowStack)
                wrapper.addArrangedSubview(rightSpacer)

                addLetterKeys(row, into: rowStack)
                containerStack.addArrangedSubview(wrapper)
                continue
            }

            // 第三排：左右各一个功能键
            if rowIndex == 2 {
                let wrapper = makeRowStack()
                wrapper.distribution = .fill
                wrapper.spacing = keySpacing

                let leftKey: KeyButton
                if isNumberMode {
                    leftKey = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
                    leftKey.setTitle("#+=", for: .normal)
                    leftKey.titleLabel?.font = Self.functionalFont(isIPad: isIPad)
                    leftKey.addTarget(self, action: #selector(modeSwitchTapped), for: .touchUpInside)
                } else {
                    leftKey = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
                    leftKey.setTitle("中/英", for: .normal)
                    leftKey.titleLabel?.font = Self.functionalFont(isIPad: isIPad).withSize(isIPad ? 16 : 14)
                    leftKey.addTarget(self, action: #selector(shiftTapped), for: .touchUpInside)
                    modeToggleButton = leftKey
                    updateModeToggleAppearance()
                }
                leftKey.widthAnchor.constraint(equalToConstant: functionalKeyWidth).isActive = true
                wrapper.addArrangedSubview(leftKey)

                let rowStack = makeRowStack()
                addLetterKeys(row, into: rowStack)
                wrapper.addArrangedSubview(rowStack)

                let del = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
                del.setImage(Self.symbolImage("delete.left", isIPad: isIPad), for: .normal)
                del.tintColor = .label
                del.addTarget(self, action: #selector(deleteTouchDown), for: .touchDown)
                del.addTarget(self, action: #selector(deleteTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
                del.widthAnchor.constraint(equalToConstant: functionalKeyWidth).isActive = true
                deleteButton = del
                wrapper.addArrangedSubview(del)

                containerStack.addArrangedSubview(wrapper)
                continue
            }

            // 第一排：普通行
            let rowStack = makeRowStack()
            addLetterKeys(row, into: rowStack)
            containerStack.addArrangedSubview(rowStack)
        }

        // 底部行
        let bottom = makeRowStack()
        bottom.distribution = .fill
        bottom.spacing = keySpacing

        // 底部键宽度根据屏幕等比计算
        let bottomSmallWidth = letterKeyWidth * 1.2
        let returnWidth = letterKeyWidth * 2.6

        if showGlobeKey {
            let globe = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
            globe.setImage(Self.symbolImage("globe", isIPad: isIPad), for: .normal)
            globe.tintColor = .label
            globe.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)
            globe.widthAnchor.constraint(equalToConstant: bottomSmallWidth).isActive = true
            bottom.addArrangedSubview(globe)
        }

        let modeBtn = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
        modeBtn.setTitle(isNumberMode ? "ABC" : "123", for: .normal)
        modeBtn.titleLabel?.font = Self.functionalFont(isIPad: isIPad)
        modeBtn.addTarget(self, action: #selector(modeSwitchTapped), for: .touchUpInside)
        modeBtn.widthAnchor.constraint(equalToConstant: bottomSmallWidth).isActive = true
        bottom.addArrangedSubview(modeBtn)

        let space = KeyButton(style: .letter, cornerRadius: keyCornerRadius)
        space.setTitle(isEnglishMode ? "space" : "空格", for: .normal)
        space.titleLabel?.font = UIFont.systemFont(ofSize: isIPad ? 17 : 16, weight: .regular)
        space.tagKey = " "
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        // 空格键不设固定宽度，让它填满剩余空间
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottom.addArrangedSubview(space)

        let returnBtn = KeyButton(style: .accent, cornerRadius: keyCornerRadius)
        returnBtn.setTitle("换行", for: .normal)
        returnBtn.titleLabel?.font = UIFont.systemFont(ofSize: isIPad ? 17 : 16, weight: .medium)
        returnBtn.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        returnBtn.widthAnchor.constraint(equalToConstant: returnWidth).isActive = true
        bottom.addArrangedSubview(returnBtn)

        containerStack.addArrangedSubview(bottom)

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edgeInset),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edgeInset),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    private func makeRowStack() -> UIStackView {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = keySpacing
        s.alignment = .fill
        s.distribution = .fillEqually
        return s
    }

    private func addLetterKeys(_ row: [String], into stack: UIStackView) {
        for key in row {
            let button = KeyButton(style: .letter, cornerRadius: keyCornerRadius)
            button.setTitle(key, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(
                ofSize: isIPad ? 24 : 23, weight: .light)
            button.tagKey = key.lowercased()
            button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
            keyButtons.append(button)
        }
    }

    // MARK: - Appearance helpers

    private static let keyboardBackgroundColor: UIColor = {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1.0)
                : UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1.0)
        }
    }()

    private static func functionalFont(isIPad: Bool) -> UIFont {
        UIFont.systemFont(ofSize: isIPad ? 18 : 16, weight: .regular)
    }

    private static func symbolImage(_ name: String, isIPad: Bool, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        let cfg = UIImage.SymbolConfiguration(pointSize: isIPad ? 22 : 19, weight: weight)
        return UIImage(systemName: name, withConfiguration: cfg)
    }

    private func updateModeToggleAppearance() {
        guard let btn = modeToggleButton else { return }
        btn.setStyle(isEnglishMode ? .functionalActive : .functional)
    }

    // MARK: - Actions

    @objc private func keyTapped(_ sender: KeyButton) {
        guard let key = sender.tagKey else { return }
        delegate?.keyboardView(self, didTapKey: key)
    }

    @objc private func shiftTapped() {
        delegate?.keyboardViewDidTapShift(self)
    }

    @objc private func deleteTouchDown() {
        deleteRepeatStarted = false
        delegate?.keyboardViewDidTapBackspace(self)
        deleteTimer?.invalidate()
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.deleteRepeatStarted = true
            self.deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.delegate?.keyboardViewDidTapBackspace(self)
            }
        }
    }

    @objc private func deleteTouchUp() {
        deleteTimer?.invalidate()
        deleteTimer = nil
        deleteRepeatStarted = false
    }

    @objc private func spaceTapped() {
        delegate?.keyboardViewDidTapSpace(self)
    }

    @objc private func returnTapped() {
        delegate?.keyboardViewDidTapReturn(self)
    }

    @objc private func globeTapped() {
        delegate?.keyboardViewDidTapGlobe(self)
    }

    @objc private func modeSwitchTapped() {
        isNumberMode.toggle()
        buildKeys()
    }
}

// MARK: - KeyButton

final class KeyButton: UIButton {

    enum Style {
        case letter
        case functional
        case functionalActive
        case accent
    }

    var tagKey: String?

    private var style: Style = .letter

    init(style: Style, cornerRadius: CGFloat) {
        super.init(frame: .zero)
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 0
        translatesAutoresizingMaskIntoConstraints = false
        adjustsImageWhenHighlighted = false
        setStyle(style)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setStyle(_ s: Style) {
        self.style = s
        switch s {
        case .letter:
            backgroundColor = Self.letterBg
            setTitleColor(.label, for: .normal)
        case .functional:
            backgroundColor = Self.functionalBg
            setTitleColor(.label, for: .normal)
        case .functionalActive:
            backgroundColor = Self.letterBg
            setTitleColor(.systemBlue, for: .normal)
        case .accent:
            backgroundColor = .systemBlue
            setTitleColor(.white, for: .normal)
        }
    }

    override var isHighlighted: Bool {
        didSet { updateHighlight() }
    }

    private func updateHighlight() {
        let target: UIColor
        if isHighlighted {
            switch style {
            case .letter, .functionalActive:
                target = Self.functionalBg
            case .functional:
                target = Self.letterBg
            case .accent:
                target = UIColor.systemBlue.withAlphaComponent(0.75)
            }
        } else {
            switch style {
            case .letter, .functionalActive:
                target = Self.letterBg
            case .functional:
                target = Self.functionalBg
            case .accent:
                target = .systemBlue
            }
        }
        UIView.animate(withDuration: 0.06) {
            self.backgroundColor = target
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.shadowColor = UIColor.black.cgColor
    }

    // MARK: Colors

    static let letterBg: UIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.42, blue: 0.43, alpha: 1.0)
            : .white
    }

    static let functionalBg: UIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.27, green: 0.27, blue: 0.28, alpha: 1.0)
            : UIColor(red: 0.68, green: 0.71, blue: 0.74, alpha: 1.0)
    }
}
