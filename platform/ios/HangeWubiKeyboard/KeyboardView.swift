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

/// 键盘尺寸断点（唯一出处）。只依据键盘容器的实际宽度与 verticalSizeClass，不看机型 / idiom / 整屏。
///
/// | 条件                              | 键区高度 | 尺寸档 | 典型场景                                 |
/// |-----------------------------------|---------|-------|------------------------------------------|
/// | verticalSizeClass == .compact     | 162     | 常规  | iPhone 横屏（与旧值一致）                    |
/// | 宽 < 600                          | 216     | 常规  | iPhone 竖屏、iPad 浮动键盘（与旧 iPhone 值一致） |
/// | 600 ≤ 宽 < 744                    | 250     | 大    | 推算值：折叠屏内屏展开（近方形）              |
/// | 744 ≤ 宽 < 1100                   | 280     | 大    | iPad 竖屏（与旧值一致）                      |
/// | 宽 ≥ 1100                         | 220     | 大    | iPad 横屏（与旧值一致）                      |
///
/// 600 / 744 / 250 为推算值：iPhone 竖屏最宽 ~440pt，iPad mini 竖屏 744pt，
/// 折叠屏内屏（~7.6 英寸）官方 point 尺寸未公布，落在两者之间；待真机校准时只改这里。
enum KeyboardMetrics {
    static let candidateBarHeight: CGFloat = 40

    private static let largeLayoutMinWidth: CGFloat = 600
    private static let iPadPortraitMinWidth: CGFloat = 744
    private static let iPadLandscapeMinWidth: CGFloat = 1100

    /// 键区（不含候选栏）高度
    static func keyboardHeight(width: CGFloat, verticalSizeClass: UIUserInterfaceSizeClass) -> CGFloat {
        if verticalSizeClass == .compact { return 162 }
        if width < largeLayoutMinWidth { return 216 }
        if width < iPadPortraitMinWidth { return 250 }
        if width < iPadLandscapeMinWidth { return 280 }
        return 220
    }

    /// 大尺寸档：更大的键距 / 圆角 / 字号
    static func isLargeLayout(width: CGFloat, verticalSizeClass: UIUserInterfaceSizeClass) -> Bool {
        verticalSizeClass != .compact && width >= largeLayoutMinWidth
    }
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

    /// 当前 buildKeys() 所用的尺寸档；宽度跨档时在 layoutSubviews 中重建
    private var isLargeLayout = false

    private var currentIsLargeLayout: Bool {
        KeyboardMetrics.isLargeLayout(width: bounds.width, verticalSizeClass: traitCollection.verticalSizeClass)
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

    private var keySpacing: CGFloat { isLargeLayout ? 8 : 6 }
    private var rowSpacing: CGFloat { isLargeLayout ? 12 : 11 }
    private var edgeInset: CGFloat { isLargeLayout ? 6 : 3 }
    private var keyCornerRadius: CGFloat { isLargeLayout ? 6 : 5 }

    private var currentRows: [[String]] {
        if isSymbolMode { return symbolRows }
        if isNumberMode { return numberRows }
        return letterRows
    }

    /// 按可用宽度 W（= containerStack 宽度）等比约束：width = W × fraction + keySpacing × spacingFactor。
    /// 字母键宽 = (W - 9s) / 10 = 0.1W - 0.9s，其余键宽均为其线性组合，宽度任意变化时自动重排。
    private func proportionalWidth(_ view: UIView, of container: UIView,
                                   fraction: CGFloat, spacingFactor: CGFloat) -> NSLayoutConstraint {
        view.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: fraction,
                                    constant: spacingFactor * keySpacing)
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

    override func layoutSubviews() {
        if currentIsLargeLayout != isLargeLayout { buildKeys() }
        super.layoutSubviews()
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
        isLargeLayout = currentIsLargeLayout

        let rows = currentRows
        var widthConstraints: [NSLayoutConstraint] = []

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
                let rightSpacer = UIView()
                rightSpacer.translatesAutoresizingMaskIntoConstraints = false
                // 缩进 = (字母键宽 + 键距) / 2 = 0.05W + 0.05s
                for spacer in [leftSpacer, rightSpacer] {
                    widthConstraints.append(proportionalWidth(spacer, of: containerStack,
                                                              fraction: 0.05, spacingFactor: 0.05))
                }

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

                // 功能键宽 = (W - n×字母键宽 - (n+1)s) / 2，n 为本行字符键数
                let n = CGFloat(row.count)
                let functionalFraction = (1 - 0.1 * n) / 2
                let functionalSpacingFactor = -(0.1 * n + 1) / 2

                let leftKey: KeyButton
                if isNumberMode || isSymbolMode {
                    leftKey = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
                    leftKey.setTitle(isSymbolMode ? "123" : "#+=", for: .normal)
                    leftKey.titleLabel?.font = Self.functionalFont(isLargeLayout: isLargeLayout)
                    leftKey.addTarget(self, action: #selector(symbolToggleTapped), for: .touchUpInside)
                } else {
                    leftKey = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
                    leftKey.titleLabel?.font = Self.functionalFont(isLargeLayout: isLargeLayout).withSize(isLargeLayout ? 16 : 14)
                    leftKey.addTarget(self, action: #selector(shiftTapped), for: .touchUpInside)
                    modeToggleButton = leftKey
                    updateModeToggleAppearance()
                    updateModeToggleLabel()
                }
                leftKey.addTarget(self, action: #selector(functionalTouchDown), for: .touchDown)
                widthConstraints.append(proportionalWidth(leftKey, of: containerStack,
                                                          fraction: functionalFraction,
                                                          spacingFactor: functionalSpacingFactor))
                wrapper.addArrangedSubview(leftKey)

                let rowStack = makeRowStack()
                addLetterKeys(row, into: rowStack)
                wrapper.addArrangedSubview(rowStack)

                let del = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
                del.setImage(Self.symbolImage("delete.left", isLargeLayout: isLargeLayout), for: .normal)
                del.tintColor = .label
                del.addTarget(self, action: #selector(deleteTouchDown), for: .touchDown)
                del.addTarget(self, action: #selector(deleteTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
                widthConstraints.append(proportionalWidth(del, of: containerStack,
                                                          fraction: functionalFraction,
                                                          spacingFactor: functionalSpacingFactor))
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

        // 小功能键 = 1.2 × 字母键宽，换行键 = 2.6 × 字母键宽
        func bottomSmallWidth(_ v: UIView) -> NSLayoutConstraint {
            proportionalWidth(v, of: containerStack, fraction: 0.12, spacingFactor: -1.08)
        }

        if showGlobeKey {
            let globe = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
            globe.setImage(Self.symbolImage("globe", isLargeLayout: isLargeLayout), for: .normal)
            globe.tintColor = .label
            globe.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)
            globe.addTarget(self, action: #selector(functionalTouchDown), for: .touchDown)
            widthConstraints.append(bottomSmallWidth(globe))
            bottom.addArrangedSubview(globe)
        }

        let modeBtn = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
        modeBtn.setTitle((isNumberMode || isSymbolMode) ? "ABC" : "123", for: .normal)
        modeBtn.titleLabel?.font = Self.functionalFont(isLargeLayout: isLargeLayout)
        modeBtn.addTarget(self, action: #selector(modeSwitchTapped), for: .touchUpInside)
        modeBtn.addTarget(self, action: #selector(functionalTouchDown), for: .touchDown)
        widthConstraints.append(bottomSmallWidth(modeBtn))
        bottom.addArrangedSubview(modeBtn)

        let space = KeyButton(style: .letter, cornerRadius: keyCornerRadius)
        space.titleLabel?.font = UIFont.systemFont(ofSize: isLargeLayout ? 16 : 15, weight: .regular)
        space.setTitleColor(Self.spaceLabelColor, for: .normal)
        space.tagKey = " "
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        space.addTarget(self, action: #selector(functionalTouchDown), for: .touchDown)
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spaceButton = space
        bottom.addArrangedSubview(space)
        updateSpaceLabel()

        let returnBtn = KeyButton(style: .functional, cornerRadius: keyCornerRadius)
        returnBtn.titleLabel?.font = UIFont.systemFont(ofSize: isLargeLayout ? 17 : 16, weight: .regular)
        returnBtn.setTitle(returnTitle, for: .normal)
        returnBtn.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        returnBtn.addTarget(self, action: #selector(functionalTouchDown), for: .touchDown)
        widthConstraints.append(proportionalWidth(returnBtn, of: containerStack,
                                                  fraction: 0.26, spacingFactor: -2.34))
        returnButton = returnBtn
        bottom.addArrangedSubview(returnBtn)
        updateReturnStyle()

        containerStack.addArrangedSubview(bottom)

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            // 左右贴 safe area：横屏时避开灵动岛/圆角
            containerStack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: edgeInset),
            containerStack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -edgeInset),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ] + widthConstraints)

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
                ofSize: isLargeLayout ? 24 : 23, weight: .regular)
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

    private static func functionalFont(isLargeLayout: Bool) -> UIFont {
        UIFont.systemFont(ofSize: isLargeLayout ? 18 : 16, weight: .regular)
    }

    private static func symbolImage(_ name: String, isLargeLayout: Bool, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        let cfg = UIImage.SymbolConfiguration(pointSize: isLargeLayout ? 22 : 19, weight: weight)
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
        // 可绘制区域：水平限于本视图，向上可延伸到父视图（候选栏区域）顶部
        let topLimit = -self.frame.minY
        let limits = CGRect(x: 0, y: topLimit, width: bounds.width, height: bounds.height - topLimit)
        keyPreview.show(over: frame, character: text, isLargeLayout: isLargeLayout, within: limits)
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
        setStyle(style)
        if #available(iOS 17, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: KeyButton, _: UITraitCollection) in
                self.layer.shadowColor = UIColor.black.cgColor
            }
        }
    }

    /// 替代已弃用的 adjustsImageWhenHighlighted = false：高亮态显式使用同一张图，按下时图标不变暗
    override func setImage(_ image: UIImage?, for state: UIControl.State) {
        super.setImage(image, for: state)
        if state == .normal { super.setImage(image, for: .highlighted) }
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
        // iOS 17+ 走 init 中的 registerForTraitChanges
        if #unavailable(iOS 17) {
            layer.shadowColor = UIColor.black.cgColor
        }
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
