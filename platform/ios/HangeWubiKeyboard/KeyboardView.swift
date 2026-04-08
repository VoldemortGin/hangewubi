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

/// iOS 系统风格的键盘视图。布局参照系统五笔键盘：
/// - 字母键白底，功能键浅灰底，回车蓝底
/// - 中/英 切换键替代 Shift 位置
/// - 使用 SF Symbols 渲染功能图标
class KeyboardView: UIView {

    weak var delegate: KeyboardViewDelegate?

    private var keyButtons: [KeyButton] = []
    private var modeToggleButton: KeyButton?  // 中/英 切换
    private var deleteButton: KeyButton?
    private var deleteTimer: Timer?
    private var deleteRepeatStarted = false

    /// 当前是否处于英文模式（影响中/英切换按键的高亮）
    var isEnglishMode = false {
        didSet { updateModeToggleAppearance() }
    }

    private(set) var isNumberMode = false

    var showGlobeKey: Bool = true {
        didSet {
            if oldValue != showGlobeKey {
                buildKeys()
            }
        }
    }

    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    // MARK: - Layouts

    private let letterRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]

    private let numberRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "¥", "&", "@", "\""],
        [".", ",", "?", "!", "'"],
    ]

    // MARK: - Layout constants

    private var keySpacing: CGFloat { isIPad ? 8 : 6 }
    private var rowSpacing: CGFloat { isIPad ? 12 : 11 }
    private var edgeInset: CGFloat { isIPad ? 6 : 3 }
    private var keyCornerRadius: CGFloat { isIPad ? 6 : 5 }

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
        // 系统会自动重绘 dynamic colors，无需重建按键
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
            let rowStack = makeRowStack()

            // 字母模式第二排两侧加 padding
            if !isNumberMode && rowIndex == 1 {
                let wrapper = makeRowStack()
                wrapper.distribution = .fill
                let leftSpacer = UIView()
                leftSpacer.translatesAutoresizingMaskIntoConstraints = false
                leftSpacer.widthAnchor.constraint(equalToConstant: 18).isActive = true
                let rightSpacer = UIView()
                rightSpacer.translatesAutoresizingMaskIntoConstraints = false
                rightSpacer.widthAnchor.constraint(equalToConstant: 18).isActive = true

                wrapper.addArrangedSubview(leftSpacer)
                wrapper.addArrangedSubview(rowStack)
                wrapper.addArrangedSubview(rightSpacer)

                addLetterKeys(row, into: rowStack)
                containerStack.addArrangedSubview(wrapper)
                continue
            }

            // 第三排：左边 中/英 或 #+= ，右边删除
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
                let leftWidth: CGFloat = isIPad ? 70 : 44
                leftKey.widthAnchor.constraint(equalToConstant: leftWidth).isActive = true
                wrapper.addArrangedSubview(leftKey)

                wrapper.addArrangedSubview(rowStack)

                let del = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
                del.setImage(Self.symbolImage("delete.left", isIPad: isIPad), for: .normal)
                del.tintColor = .label
                del.addTarget(self, action: #selector(deleteTouchDown), for: .touchDown)
                del.addTarget(self, action: #selector(deleteTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
                let delWidth: CGFloat = isIPad ? 70 : 44
                del.widthAnchor.constraint(equalToConstant: delWidth).isActive = true
                deleteButton = del
                wrapper.addArrangedSubview(del)

                addLetterKeys(row, into: rowStack)
                containerStack.addArrangedSubview(wrapper)
                continue
            }

            // 普通行
            addLetterKeys(row, into: rowStack)
            containerStack.addArrangedSubview(rowStack)
        }

        // 底部行
        let bottom = makeRowStack()
        bottom.distribution = .fill
        bottom.spacing = keySpacing

        let smallWidth: CGFloat = isIPad ? 60 : 42
        let modeWidth: CGFloat = isIPad ? 70 : 48
        let returnWidth: CGFloat = isIPad ? 120 : 88

        if showGlobeKey {
            let globe = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
            globe.setImage(Self.symbolImage("globe", isIPad: isIPad), for: .normal)
            globe.tintColor = .label
            globe.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)
            globe.widthAnchor.constraint(equalToConstant: smallWidth).isActive = true
            bottom.addArrangedSubview(globe)
        }

        let modeBtn = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
        modeBtn.setTitle(isNumberMode ? "ABC" : "123", for: .normal)
        modeBtn.titleLabel?.font = Self.functionalFont(isIPad: isIPad)
        modeBtn.addTarget(self, action: #selector(modeSwitchTapped), for: .touchUpInside)
        modeBtn.widthAnchor.constraint(equalToConstant: modeWidth).isActive = true
        bottom.addArrangedSubview(modeBtn)

        let space = KeyButton(style: .letter, cornerRadius: keyCornerRadius)
        space.setTitle("空格", for: .normal)
        space.titleLabel?.font = UIFont.systemFont(ofSize: isIPad ? 17 : 15, weight: .regular)
        space.tagKey = " "
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        bottom.addArrangedSubview(space)

        let period = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
        period.setTitle("。", for: .normal)
        period.titleLabel?.font = UIFont.systemFont(ofSize: isIPad ? 22 : 20)
        period.tagKey = "。"
        period.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        period.widthAnchor.constraint(equalToConstant: smallWidth).isActive = true
        bottom.addArrangedSubview(period)

        let returnBtn = KeyButton(style: .accent, cornerRadius: keyCornerRadius)
        returnBtn.setImage(Self.symbolImage("return.left", isIPad: isIPad, weight: .semibold), for: .normal)
        returnBtn.tintColor = .white
        returnBtn.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        returnBtn.widthAnchor.constraint(equalToConstant: returnWidth).isActive = true
        bottom.addArrangedSubview(returnBtn)

        containerStack.addArrangedSubview(bottom)

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edgeInset),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edgeInset),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
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
                ofSize: isIPad ? 24 : 22, weight: .regular)
            button.tagKey = key
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
        if isEnglishMode {
            btn.setStyle(.functionalActive)
        } else {
            btn.setStyle(.functional)
        }
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

/// 键盘按键。统一处理风格、按下高亮、阴影。
final class KeyButton: UIButton {

    enum Style {
        case letter            // 字母键 — 白底（dark 模式更亮的灰）
        case functional        // 功能键 — 浅灰底
        case functionalActive  // 功能键高亮态（中/英 当前为英文）
        case accent            // 强调键 — 蓝底（回车）
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

    // 在子类化按键里能可靠跟踪 dark mode 切换
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 颜色用 dynamic UIColor，会自动更新；shadow 颜色单独处理
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
