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

class KeyboardView: UIView {

    weak var delegate: KeyboardViewDelegate?

    private var keyButtons: [UIButton] = []
    private var shiftButton: UIButton?
    private var deleteButton: UIButton?
    private var deleteTimer: Timer?

    private(set) var isShifted = false
    private(set) var isNumberMode = false

    // Key layouts
    private let letterRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]

    private let numberRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'"],
    ]

    private var rowStackViews: [UIStackView] = []
    private var bottomRow: UIStackView?

    // Layout constants
    private let keySpacing: CGFloat = 6
    private let rowSpacing: CGFloat = 10
    private let keyCornerRadius: CGFloat = 5
    private let edgeInset: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupKeyboard()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupKeyboard()
    }

    private func setupKeyboard() {
        backgroundColor = UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1.0)
        buildKeys()
    }

    private func buildKeys() {
        // Clear existing
        subviews.forEach { $0.removeFromSuperview() }
        keyButtons.removeAll()
        rowStackViews.removeAll()

        let rows = isNumberMode ? numberRows : letterRows

        // Container stack for all rows
        let containerStack = UIStackView()
        containerStack.axis = .vertical
        containerStack.spacing = rowSpacing
        containerStack.alignment = .fill
        containerStack.distribution = .fillEqually
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerStack)

        // Build letter/number rows
        for (rowIndex, row) in rows.enumerated() {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = keySpacing
            rowStack.alignment = .fill
            rowStack.distribution = .fillEqually

            // Row 2 (middle row) needs side padding for letter mode
            if !isNumberMode && rowIndex == 1 {
                let wrapper = UIStackView()
                wrapper.axis = .horizontal
                wrapper.spacing = 0
                wrapper.alignment = .fill

                let leftSpacer = UIView()
                leftSpacer.translatesAutoresizingMaskIntoConstraints = false
                leftSpacer.widthAnchor.constraint(equalToConstant: 16).isActive = true

                let rightSpacer = UIView()
                rightSpacer.translatesAutoresizingMaskIntoConstraints = false
                rightSpacer.widthAnchor.constraint(equalToConstant: 16).isActive = true

                wrapper.addArrangedSubview(leftSpacer)
                wrapper.addArrangedSubview(rowStack)
                wrapper.addArrangedSubview(rightSpacer)

                for key in row {
                    let button = makeKeyButton(title: displayTitle(for: key), tag: key)
                    rowStack.addArrangedSubview(button)
                    keyButtons.append(button)
                }

                containerStack.addArrangedSubview(wrapper)
                rowStackViews.append(rowStack)
                continue
            }

            // Row 3 (bottom letter row) has shift and delete
            if rowIndex == 2 {
                let wrapper = UIStackView()
                wrapper.axis = .horizontal
                wrapper.spacing = keySpacing
                wrapper.alignment = .fill

                if isNumberMode {
                    // Number mode: # and delete
                    let hashButton = makeSpecialKeyButton(
                        title: "#+=", color: specialKeyColor
                    )
                    hashButton.addTarget(self, action: #selector(modeSwitchTapped), for: .touchUpInside)
                    hashButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
                    wrapper.addArrangedSubview(hashButton)
                } else {
                    let shift = makeSpecialKeyButton(
                        title: "\u{21E7}", color: specialKeyColor
                    )
                    shift.addTarget(self, action: #selector(shiftTapped), for: .touchUpInside)
                    shift.widthAnchor.constraint(equalToConstant: 44).isActive = true
                    shiftButton = shift
                    wrapper.addArrangedSubview(shift)
                }

                wrapper.addArrangedSubview(rowStack)

                let del = makeSpecialKeyButton(
                    title: "\u{232B}", color: specialKeyColor
                )
                del.addTarget(self, action: #selector(deleteTouchDown), for: .touchDown)
                del.addTarget(self, action: #selector(deleteTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
                del.widthAnchor.constraint(equalToConstant: 44).isActive = true
                deleteButton = del
                wrapper.addArrangedSubview(del)

                for key in row {
                    let button = makeKeyButton(title: displayTitle(for: key), tag: key)
                    rowStack.addArrangedSubview(button)
                    keyButtons.append(button)
                }

                containerStack.addArrangedSubview(wrapper)
                rowStackViews.append(rowStack)
                continue
            }

            // Normal rows
            for key in row {
                let button = makeKeyButton(title: displayTitle(for: key), tag: key)
                rowStack.addArrangedSubview(button)
                keyButtons.append(button)
            }

            containerStack.addArrangedSubview(rowStack)
            rowStackViews.append(rowStack)
        }

        // Bottom row: globe, 123/ABC, space, period, return
        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.spacing = keySpacing
        bottom.alignment = .fill

        let globeButton = makeSpecialKeyButton(title: "\u{1F310}", color: specialKeyColor)
        globeButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        globeButton.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)

        let modeButton = makeSpecialKeyButton(
            title: isNumberMode ? "ABC" : "123", color: specialKeyColor
        )
        modeButton.addTarget(self, action: #selector(modeSwitchTapped), for: .touchUpInside)

        let spaceButton = makeKeyButton(title: "空格", tag: " ")
        spaceButton.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        // Remove the default letter key action
        spaceButton.removeTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)

        let periodButton = makeKeyButton(title: "。", tag: "。")

        let returnButton = makeSpecialKeyButton(title: "换行", color: .systemBlue)
        returnButton.setTitleColor(.white, for: .normal)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)

        bottom.addArrangedSubview(globeButton)
        bottom.addArrangedSubview(modeButton)
        bottom.addArrangedSubview(spaceButton)
        bottom.addArrangedSubview(periodButton)
        bottom.addArrangedSubview(returnButton)

        // Width constraints for bottom row
        globeButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        modeButton.widthAnchor.constraint(equalToConstant: 50).isActive = true
        periodButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        returnButton.widthAnchor.constraint(equalToConstant: 88).isActive = true

        containerStack.addArrangedSubview(bottom)
        bottomRow = bottom

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edgeInset),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edgeInset),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    private var specialKeyColor: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? UIColor(white: 0.42, alpha: 1.0)
                : UIColor(red: 0.68, green: 0.70, blue: 0.73, alpha: 1.0)
        }
    }

    private var keyBackgroundColor: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? UIColor(white: 0.32, alpha: 1.0)
                : .white
        }
    }

    private func displayTitle(for key: String) -> String {
        if isShifted && key.count == 1 && key.first!.isLetter {
            return key.uppercased()
        }
        return key
    }

    private func makeKeyButton(title: String, tag: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 22)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = keyBackgroundColor
        button.layer.cornerRadius = keyCornerRadius
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowOpacity = 0.2
        button.layer.shadowRadius = 0.5
        button.accessibilityIdentifier = tag
        button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        button.addTarget(self, action: #selector(keyTouchDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(keyTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return button
    }

    private func makeSpecialKeyButton(title: String, color: UIColor) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = color
        button.layer.cornerRadius = keyCornerRadius
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowOpacity = 0.2
        button.layer.shadowRadius = 0.5
        return button
    }

    // MARK: - Key Actions

    @objc private func keyTapped(_ sender: UIButton) {
        guard let key = sender.accessibilityIdentifier else { return }
        if isShifted && key.count == 1 && key.first!.isLetter {
            delegate?.keyboardView(self, didTapKey: key.uppercased())
            setShifted(false)
        } else {
            delegate?.keyboardView(self, didTapKey: key)
        }
    }

    @objc private func keyTouchDown(_ sender: UIButton) {
        UIView.animate(withDuration: 0.05) {
            sender.backgroundColor = .systemGray4
            sender.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
        }
    }

    @objc private func keyTouchUp(_ sender: UIButton) {
        UIView.animate(withDuration: 0.1) {
            sender.backgroundColor = self.keyBackgroundColor
            sender.transform = .identity
        }
    }

    @objc private func shiftTapped() {
        setShifted(!isShifted)
        delegate?.keyboardViewDidTapShift(self)
    }

    @objc private func deleteTouchDown() {
        delegate?.keyboardViewDidTapBackspace(self)
        // Start repeat timer
        deleteTimer?.invalidate()
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.delegate?.keyboardViewDidTapBackspace(self!)
        }
    }

    @objc private func deleteTouchUp() {
        deleteTimer?.invalidate()
        deleteTimer = nil
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

    // MARK: - Public

    func setShifted(_ shifted: Bool) {
        isShifted = shifted
        shiftButton?.backgroundColor = shifted ? .white : specialKeyColor

        // Update key titles
        for button in keyButtons {
            guard let key = button.accessibilityIdentifier,
                  key.count == 1, key.first!.isLetter else { continue }
            button.setTitle(shifted ? key.uppercased() : key.lowercased(), for: .normal)
        }
    }
}
