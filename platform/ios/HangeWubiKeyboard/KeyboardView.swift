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

/// iOS 系统风格键盘视图，视觉对齐苹果简体中文键盘
class KeyboardView: UIView {

    /// 换行键样式：普通(灰)对应 .default 换行；action(蓝)对应搜索/发送/完成等
    enum ReturnStyle {
        case normal
        case action
    }

    weak var delegate: KeyboardViewDelegate?

    private var keyButtons: [KeyButton] = []
    private var modeToggleButton: KeyButton?
    private var deleteButton: KeyButton?
    private var returnButton: KeyButton?
    private var spaceButton: KeyButton?
    private var deleteTimer: Timer?
    private var deleteRepeatStarted = false

    private let keyPreview = KeyPreviewView()

    private var impactGen: UIImpactFeedbackGenerator?

    // MARK: - Public state

    var hapticEnabled: Bool = false {
        didSet {
            if hapticEnabled {
                if impactGen == nil {
                    impactGen = UIImpactFeedbackGenerator(style: .light)
                    impactGen?.prepare()
                }
            } else {
                impactGen = nil
            }
        }
    }

    var isEnglishMode = false {
        didSet {
            updateModeToggleAppearance()
            updateSpaceLabel()
        }
    }

    private(set) var isNumberMode = false
    private(set) var isSymbolMode = false

    var returnTitle: String = "换行" {
        didSet { returnButton?.setTitle(returnTitle, for: .normal) }
    }

    var returnStyle: ReturnStyle = .normal {
        didSet { updateReturnStyle() }
    }

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

    private let symbolRows: [[String]] = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "$", "£", "·"],
        [".", ",", "?", "!", "'"],
    ]

    // MARK: - 等比计算的布局参数

    private var keySpacing: CGFloat { isIPad ? 8 : 6 }
    private var rowSpacing: CGFloat { isIPad ? 12 : 11 }
    private var edgeInset: CGFloat { isIPad ? 6 : 3 }
    private var keyCornerRadius: CGFloat { isIPad ? 6 : 5 }

    private var availableWidth: CGFloat {
        let w = UIScreen.main.bounds.width
        return w - 2 * edgeInset
    }

    private var letterKeyWidth: CGFloat {
        (availableWidth - 9 * keySpacing) / 10
    }

    private var row2SidePadding: CGFloat {
        (letterKeyWidth + keySpacing) / 2
    }

    private var currentRows: [[String]] {
        if isSymbolMode { return symbolRows }
        if isNumberMode { return numberRows }
        return letterRows
    }

    private var functionalKeyWidth: CGFloat {
        let rows = currentRows
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
        clipsToBounds = false
        keyPreview.isHidden = true
        addSubview(keyPreview)
        buildKeys()
    }

    // MARK: - Build

    private func buildKeys() {
        // 清除除预览外的所有子视图
        subviews.forEach { v in
            if v !== keyPreview { v.removeFromSuperview() }
        }
        keyButtons.removeAll()
        modeToggleButton = nil
        deleteButton = nil
        returnButton = nil
        spaceButton = nil

        let rows = currentRows

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
                if isNumberMode || isSymbolMode {
                    leftKey = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
                    leftKey.setTitle(isSymbolMode ? "123" : "#+=", for: .normal)
                    leftKey.titleLabel?.font = Self.functionalFont(isIPad: isIPad)
                    leftKey.addTarget(self, action: #selector(symbolToggleTapped), for: .touchUpInside)
                } else {
                    leftKey = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
                    leftKey.titleLabel?.font = Self.functionalFont(isIPad: isIPad).withSize(isIPad ? 16 : 14)
                    leftKey.addTarget(self, action: #selector(shiftTapped), for: .touchUpInside)
                    modeToggleButton = leftKey
                    updateModeToggleAppearance()
                    updateModeToggleLabel()
                }
                leftKey.addTarget(self, action: #selector(functionalTouchDown), for: .touchDown)
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

        let bottomSmallWidth = letterKeyWidth * 1.2
        let returnWidth = letterKeyWidth * 2.6

        if showGlobeKey {
            let globe = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
            globe.setImage(Self.symbolImage("globe", isIPad: isIPad), for: .normal)
            globe.tintColor = .label
            globe.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)
            globe.addTarget(self, action: #selector(functionalTouchDown), for: .touchDown)
            globe.widthAnchor.constraint(equalToConstant: bottomSmallWidth).isActive = true
            bottom.addArrangedSubview(globe)
        }

        let modeBtn = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
        modeBtn.setTitle((isNumberMode || isSymbolMode) ? "ABC" : "123", for: .normal)
        modeBtn.titleLabel?.font = Self.functionalFont(isIPad: isIPad)
        modeBtn.addTarget(self, action: #selector(modeSwitchTapped), for: .touchUpInside)
        modeBtn.addTarget(self, action: #selector(functionalTouchDown), for: .touchDown)
        modeBtn.widthAnchor.constraint(equalToConstant: bottomSmallWidth).isActive = true
        bottom.addArrangedSubview(modeBtn)

        let space = KeyButton(style: .letter, cornerRadius: keyCornerRadius)
        space.titleLabel?.font = UIFont.systemFont(ofSize: isIPad ? 16 : 15, weight: .regular)
        space.setTitleColor(Self.spaceLabelColor, for: .normal)
        space.tagKey = " "
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        space.addTarget(self, action: #selector(functionalTouchDown), for: .touchDown)
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spaceButton = space
        bottom.addArrangedSubview(space)
        updateSpaceLabel()

        let returnBtn = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
        returnBtn.titleLabel?.font = UIFont.systemFont(ofSize: isIPad ? 17 : 16, weight: .regular)
        returnBtn.setTitle(returnTitle, for: .normal)
        returnBtn.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        returnBtn.addTarget(self, action: #selector(functionalTouchDown), for: .touchDown)
        returnBtn.widthAnchor.constraint(equalToConstant: returnWidth).isActive = true
        returnButton = returnBtn
        bottom.addArrangedSubview(returnBtn)
        updateReturnStyle()

        containerStack.addArrangedSubview(bottom)

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edgeInset),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edgeInset),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        bringSubviewToFront(keyPreview)
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
                ofSize: isIPad ? 24 : 23, weight: .regular)
            button.tagKey = key.lowercased()
            button.previewText = key
            button.addTarget(self, action: #selector(letterTouchDown(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(letterTouchUp(_:)),
                             for: [.touchUpInside, .touchUpOutside, .touchCancel])
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
                : UIColor(red: 0.82, green: 0.83, blue: 0.85, alpha: 1.0)
        }
    }()

    private static let spaceLabelColor: UIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.label.withAlphaComponent(0.75)
            : UIColor.label.withAlphaComponent(0.55)
    }

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
        updateModeToggleLabel()
    }

    private func updateModeToggleLabel() {
        guard let btn = modeToggleButton else { return }
        btn.setTitle(isEnglishMode ? "英" : "中", for: .normal)
    }

    private func updateSpaceLabel() {
        guard let btn = spaceButton else { return }
        if isEnglishMode {
            btn.setTitle("space", for: .normal)
        } else if isNumberMode || isSymbolMode {
            btn.setTitle("空格", for: .normal)
        } else {
            btn.setTitle("晗戈五笔", for: .normal)
        }
    }

    private func updateReturnStyle() {
        guard let btn = returnButton else { return }
        btn.setStyle(returnStyle == .action ? .accent : .functional)
    }

    // MARK: - Actions

    @objc private func keyTapped(_ sender: KeyButton) {
        guard let key = sender.tagKey else { return }
        delegate?.keyboardView(self, didTapKey: key)
    }

    @objc private func letterTouchDown(_ sender: KeyButton) {
        fireHaptic()
        showPreview(for: sender)
    }

    @objc private func letterTouchUp(_ sender: KeyButton) {
        hidePreview()
    }

    @objc private func functionalTouchDown() {
        fireHaptic()
    }

    @objc private func shiftTapped() {
        delegate?.keyboardViewDidTapShift(self)
    }

    @objc private func deleteTouchDown() {
        fireHaptic()
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
        isSymbolMode = false
        buildKeys()
    }

    @objc private func symbolToggleTapped() {
        isSymbolMode.toggle()
        // When toggling symbol, we stay in the number/symbol area
        // isNumberMode stays true when switching to symbols, and when switching back
        if isSymbolMode {
            isNumberMode = false
        } else {
            isNumberMode = true
        }
        buildKeys()
    }

    // MARK: - Preview / Haptic

    private func showPreview(for key: KeyButton) {
        guard let text = key.previewText else { return }
        let frame = key.convert(key.bounds, to: self)
        keyPreview.show(over: frame, character: text, isIPad: isIPad)
        bringSubviewToFront(keyPreview)
    }

    private func hidePreview() {
        keyPreview.hide()
    }

    private func fireHaptic() {
        guard hapticEnabled, let gen = impactGen else { return }
        gen.impactOccurred(intensity: 0.6)
        gen.prepare()
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
    var previewText: String?

    private var style: Style = .letter

    init(style: Style, cornerRadius: CGFloat) {
        super.init(frame: .zero)
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowOpacity = 0.35
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
            : UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1.0)
    }
}
