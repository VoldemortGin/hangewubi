import Cocoa
import InputMethodKit
import os.log

private let logger = OSLog(subsystem: "com.hangewubi.inputmethod.HangeWubi", category: "InputController")

private func debugLog(_ message: String) {
    os_log("%{public}@", log: logger, type: .default, message)
    // 同时写文件日志
    let logFile = "/tmp/hangewubi.log"
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile) {
            if let handle = FileHandle(forWritingAtPath: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logFile, contents: data)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let hangeWubiConfigChanged = Notification.Name("hangeWubiConfigChanged")
}

// MARK: - Settings

class HangeWubiSettings {
    static let shared = HangeWubiSettings()

    private let defaults: UserDefaults

    private init() {
        defaults = UserDefaults(suiteName: "com.hangewubi.inputmethod.HangeWubi") ?? UserDefaults.standard
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            // Basic - Encoding
            "autoCommitUnique4": true,
            "autoCommitFirst5": true,
            "progressiveHint": true,
            "emptyCodeAction": 0,
            "enterKeyAction": 0,
            // Basic - Candidates
            "candidateLayout": 0,
            "secondThirdSelectKey": 0,
            "candidateCount": 2,
            "plusMinusPageFlip": true,
            // Basic - Mode Toggle
            "toggleChineseEnglish": 0,
            "showModeIndicator": true,
            // Theme
            "candidateFontSize": 3,
            "firstCandidateColor": 0,
        ])
    }

    // -- Basic: Encoding --

    var autoCommitUnique4: Bool {
        get { defaults.bool(forKey: "autoCommitUnique4") }
        set { defaults.set(newValue, forKey: "autoCommitUnique4") }
    }

    var autoCommitFirst5: Bool {
        get { defaults.bool(forKey: "autoCommitFirst5") }
        set { defaults.set(newValue, forKey: "autoCommitFirst5") }
    }

    var progressiveHint: Bool {
        get { defaults.bool(forKey: "progressiveHint") }
        set { defaults.set(newValue, forKey: "progressiveHint") }
    }

    var emptyCodeAction: Int {
        get { defaults.integer(forKey: "emptyCodeAction") }
        set { defaults.set(newValue, forKey: "emptyCodeAction") }
    }

    var enterKeyAction: Int {
        get { defaults.integer(forKey: "enterKeyAction") }
        set { defaults.set(newValue, forKey: "enterKeyAction") }
    }

    // -- Basic: Candidates --

    var candidateLayout: Int {
        get { defaults.integer(forKey: "candidateLayout") }
        set { defaults.set(newValue, forKey: "candidateLayout") }
    }

    var secondThirdSelectKey: Int {
        get { defaults.integer(forKey: "secondThirdSelectKey") }
        set { defaults.set(newValue, forKey: "secondThirdSelectKey") }
    }

    var candidateCount: Int {
        get { defaults.integer(forKey: "candidateCount") }
        set { defaults.set(newValue, forKey: "candidateCount") }
    }

    var plusMinusPageFlip: Bool {
        get { defaults.bool(forKey: "plusMinusPageFlip") }
        set { defaults.set(newValue, forKey: "plusMinusPageFlip") }
    }

    // -- Basic: Mode Toggle --

    var toggleChineseEnglish: Int {
        get { defaults.integer(forKey: "toggleChineseEnglish") }
        set { defaults.set(newValue, forKey: "toggleChineseEnglish") }
    }

    var showModeIndicator: Bool {
        get { defaults.bool(forKey: "showModeIndicator") }
        set { defaults.set(newValue, forKey: "showModeIndicator") }
    }

    // -- Theme --

    var candidateFontSize: Int {
        get { defaults.integer(forKey: "candidateFontSize") }
        set { defaults.set(newValue, forKey: "candidateFontSize") }
    }

    var firstCandidateColor: Int {
        get { defaults.integer(forKey: "firstCandidateColor") }
        set { defaults.set(newValue, forKey: "firstCandidateColor") }
    }

    // -- Derived properties for backward compatibility with InputController --

    var shiftToggleEnabled: Bool {
        get { toggleChineseEnglish == 0 }
        set { toggleChineseEnglish = newValue ? 0 : 2 }
    }

    var semicolonSelectSecond: Bool {
        get { secondThirdSelectKey == 0 }
        set { secondThirdSelectKey = newValue ? 0 : 2 }
    }

    var quoteSelectThird: Bool {
        get { secondThirdSelectKey == 0 }
        set { secondThirdSelectKey = newValue ? 0 : 2 }
    }

    var plusEqualsNextPage: Bool {
        get { plusMinusPageFlip }
        set { plusMinusPageFlip = newValue }
    }

    var minusPrevPage: Bool {
        get { plusMinusPageFlip }
        set { plusMinusPageFlip = newValue }
    }

    // Helper: actual candidate count number from index
    var candidateCountValue: Int {
        let options = [3, 4, 5, 6, 7, 8, 9]
        let idx = max(0, min(candidateCount, options.count - 1))
        return options[idx]
    }

    // Helper: actual font size from index
    var candidateFontSizeValue: CGFloat {
        let options: [CGFloat] = [14, 16, 18, 20, 22, 24]
        let idx = max(0, min(candidateFontSize, options.count - 1))
        return options[idx]
    }
}

// MARK: - Preferences Window

class PreferencesWindow: NSWindow, NSTabViewDelegate {
    static let shared = PreferencesWindow()

    private var tabView: NSTabView!

    // Controls that need state refresh
    private var autoCommitUnique4Check: NSButton!
    private var autoCommitFirst5Check: NSButton!
    private var progressiveHintCheck: NSButton!
    private var emptyCodePopup: NSPopUpButton!
    private var enterKeyPopup: NSPopUpButton!
    private var candidateLayoutPopup: NSPopUpButton!
    private var secondThirdSelectPopup: NSPopUpButton!
    private var candidateCountPopup: NSPopUpButton!
    private var plusMinusPageFlipCheck: NSButton!
    private var toggleChineseEnglishPopup: NSPopUpButton!
    private var showModeIndicatorCheck: NSButton!
    private var candidateFontSizePopup: NSPopUpButton!
    private var firstCandidateColorPopup: NSPopUpButton!

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 550),
                   styleMask: [.titled, .closable],
                   backing: .buffered, defer: true)
        self.title = "晗戈五笔 设置"
        self.isReleasedWhenClosed = false
        self.center()
        setupUI()
    }

    // MARK: - UI Construction

    private func setupUI() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 550))
        self.contentView = container

        tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 600, height: 550))
        tabView.autoresizingMask = [.width, .height]
        tabView.tabViewType = .topTabsBezelBorder
        tabView.delegate = self
        container.addSubview(tabView)

        // Tab 1: Basic
        let basicTab = NSTabViewItem(identifier: "basic")
        basicTab.label = "基本"
        if let img = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "基本") {
            basicTab.image = img
        }
        basicTab.view = buildBasicTab()
        tabView.addTabViewItem(basicTab)

        // Tab 2: Theme
        let themeTab = NSTabViewItem(identifier: "theme")
        themeTab.label = "主题"
        if let img = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: "主题") {
            themeTab.image = img
        }
        themeTab.view = buildThemeTab()
        tabView.addTabViewItem(themeTab)

        // Tab 3: About
        let aboutTab = NSTabViewItem(identifier: "about")
        aboutTab.label = "关于"
        if let img = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "关于") {
            aboutTab.image = img
        }
        aboutTab.view = buildAboutTab()
        tabView.addTabViewItem(aboutTab)
    }

    // MARK: - Basic Tab

    private func buildBasicTab() -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 510))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 580))
        scrollView.documentView = contentView

        let settings = HangeWubiSettings.shared
        var y: CGFloat = 580

        // --- Section: 编码 ---
        y -= 10
        y = addSectionBox(to: contentView, title: "编码", y: y, height: 210) { box, startY in
            var innerY = startY

            self.autoCommitUnique4Check = self.addCheckbox(
                to: box, title: "满4码唯一候选词直接上屏", y: &innerY,
                checked: settings.autoCommitUnique4, action: #selector(self.autoCommitUnique4Changed(_:)))

            self.autoCommitFirst5Check = self.addCheckbox(
                to: box, title: "输入第5码时首选项直接上屏", y: &innerY,
                checked: settings.autoCommitFirst5, action: #selector(self.autoCommitFirst5Changed(_:)))

            self.progressiveHintCheck = self.addCheckbox(
                to: box, title: "逐码提示", y: &innerY,
                checked: settings.progressiveHint, action: #selector(self.progressiveHintChanged(_:)))

            self.emptyCodePopup = self.addDropdownRow(
                to: box, label: "空码时：", y: &innerY,
                items: ["转临时英文状态", "发出提示音", "不做处理"],
                selected: settings.emptyCodeAction, action: #selector(self.emptyCodeActionChanged(_:)))

            self.enterKeyPopup = self.addDropdownRow(
                to: box, label: "Enter 键：", y: &innerY,
                items: ["输出编码", "清除编码", "不做处理"],
                selected: settings.enterKeyAction, action: #selector(self.enterKeyActionChanged(_:)))
        }

        y -= 16

        // --- Section: 候选词 ---
        y = addSectionBox(to: contentView, title: "候选词", y: y, height: 180) { box, startY in
            var innerY = startY

            self.candidateLayoutPopup = self.addDropdownRow(
                to: box, label: "候选词排列：", y: &innerY,
                items: ["横向", "纵向"],
                selected: settings.candidateLayout, action: #selector(self.candidateLayoutChanged(_:)))

            self.secondThirdSelectPopup = self.addDropdownRow(
                to: box, label: "二三候选词额外选择键：", y: &innerY,
                items: ["; '", "[ ]", "无"],
                selected: settings.secondThirdSelectKey, action: #selector(self.secondThirdSelectKeyChanged(_:)))

            self.candidateCountPopup = self.addDropdownRow(
                to: box, label: "候选词数量：", y: &innerY,
                items: ["3", "4", "5", "6", "7", "8", "9"],
                selected: settings.candidateCount, action: #selector(self.candidateCountChanged(_:)))

            self.plusMinusPageFlipCheck = self.addCheckbox(
                to: box, title: "使用 +/= 和 -/. 键翻页", y: &innerY,
                checked: settings.plusMinusPageFlip, action: #selector(self.plusMinusPageFlipChanged(_:)))
        }

        y -= 16

        // --- Section: 状态切换 ---
        y = addSectionBox(to: contentView, title: "状态切换", y: y, height: 100) { box, startY in
            var innerY = startY

            self.toggleChineseEnglishPopup = self.addDropdownRow(
                to: box, label: "切换中英文：", y: &innerY,
                items: ["Shift 键", "Ctrl 键", "无"],
                selected: settings.toggleChineseEnglish, action: #selector(self.toggleChineseEnglishChanged(_:)))

            self.showModeIndicatorCheck = self.addCheckbox(
                to: box, title: "切换状态时，在光标处提示中英文状态", y: &innerY,
                checked: settings.showModeIndicator, action: #selector(self.showModeIndicatorChanged(_:)))
        }

        return scrollView
    }

    // MARK: - Theme Tab

    private func buildThemeTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 510))
        let settings = HangeWubiSettings.shared
        var y: CGFloat = 510 - 10

        y = addSectionBox(to: view, title: "候选窗外观", y: y, height: 100) { box, startY in
            var innerY = startY

            self.candidateFontSizePopup = self.addDropdownRow(
                to: box, label: "字体大小：", y: &innerY,
                items: ["14", "16", "18", "20", "22", "24"],
                selected: settings.candidateFontSize, action: #selector(self.candidateFontSizeChanged(_:)))

            self.firstCandidateColorPopup = self.addDropdownRow(
                to: box, label: "首选词颜色：", y: &innerY,
                items: ["浅蓝色", "红色", "绿色", "系统强调色"],
                selected: settings.firstCandidateColor, action: #selector(self.firstCandidateColorChanged(_:)))
        }

        return view
    }

    // MARK: - About Tab

    private func buildAboutTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 510))

        // App icon
        let iconView = NSImageView(frame: NSRect(x: 250, y: 340, width: 100, height: 100))
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = appIcon
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(iconView)

        // App name
        let nameLabel = NSTextField(labelWithString: "晗戈五笔")
        nameLabel.font = NSFont.boldSystemFont(ofSize: 28)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 150, y: 300, width: 300, height: 36)
        view.addSubview(nameLabel)

        // Version
        let versionLabel = NSTextField(labelWithString: "版本 0.1.0")
        versionLabel.font = NSFont.systemFont(ofSize: 14)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: 150, y: 270, width: 300, height: 22)
        view.addSubview(versionLabel)

        // Description
        let descLabel = NSTextField(labelWithString: "基于 Rust 引擎的高性能五笔输入法")
        descLabel.font = NSFont.systemFont(ofSize: 13)
        descLabel.textColor = .secondaryLabelColor
        descLabel.alignment = .center
        descLabel.frame = NSRect(x: 100, y: 240, width: 400, height: 22)
        view.addSubview(descLabel)

        // Author
        let authorLabel = NSTextField(labelWithString: "作者：林晗")
        authorLabel.font = NSFont.systemFont(ofSize: 13)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.alignment = .center
        authorLabel.frame = NSRect(x: 150, y: 210, width: 300, height: 22)
        view.addSubview(authorLabel)

        // Email
        let emailLabel = NSTextField(labelWithString: "gin.linhan@gmail.com")
        emailLabel.font = NSFont.systemFont(ofSize: 12)
        emailLabel.textColor = .secondaryLabelColor
        emailLabel.alignment = .center
        emailLabel.frame = NSRect(x: 150, y: 188, width: 300, height: 20)
        view.addSubview(emailLabel)

        // GitHub link
        let linkButton = NSButton(title: "GitHub: hangewubi", target: self, action: #selector(openGitHub))
        linkButton.bezelStyle = .inline
        linkButton.frame = NSRect(x: 220, y: 158, width: 160, height: 24)
        view.addSubview(linkButton)

        // Copyright
        let copyrightLabel = NSTextField(labelWithString: "\u{00A9} 2026 林晗")
        copyrightLabel.font = NSFont.systemFont(ofSize: 11)
        copyrightLabel.textColor = .tertiaryLabelColor
        copyrightLabel.alignment = .center
        copyrightLabel.frame = NSRect(x: 150, y: 128, width: 300, height: 18)
        view.addSubview(copyrightLabel)

        return view
    }

    // MARK: - UI Helpers

    /// Add a grouped section box. Returns the y position after the box.
    @discardableResult
    private func addSectionBox(to parent: NSView, title: String, y: CGFloat, height: CGFloat,
                               builder: (NSView, CGFloat) -> Void) -> CGFloat {
        let boxX: CGFloat = 20
        let boxWidth: CGFloat = 540
        let boxY = y - height

        let box = NSBox(frame: NSRect(x: boxX, y: boxY, width: boxWidth, height: height))
        box.boxType = .primary
        box.title = title
        box.titleFont = NSFont.boldSystemFont(ofSize: 13)
        parent.addSubview(box)

        // Content starts inside the box; NSBox content view origin is (0,0) at bottom-left
        let contentStartY = height - 40  // leave room for title
        builder(box.contentView!, contentStartY)

        return boxY
    }

    /// Add a checkbox row inside a container. Decrements y by row height.
    @discardableResult
    private func addCheckbox(to container: NSView, title: String, y: inout CGFloat,
                             checked: Bool, action: Selector) -> NSButton {
        y -= 30
        let check = NSButton(checkboxWithTitle: title, target: self, action: action)
        check.font = NSFont.systemFont(ofSize: 13)
        check.state = checked ? .on : .off
        check.frame = NSRect(x: 20, y: y, width: 460, height: 22)
        container.addSubview(check)
        return check
    }

    /// Add a label + popup button row. Decrements y by row height.
    @discardableResult
    private func addDropdownRow(to container: NSView, label: String, y: inout CGFloat,
                                items: [String], selected: Int, action: Selector) -> NSPopUpButton {
        y -= 32
        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 13)
        lbl.frame = NSRect(x: 20, y: y, width: 200, height: 22)
        lbl.alignment = .right
        container.addSubview(lbl)

        let popup = NSPopUpButton(frame: NSRect(x: 228, y: y - 2, width: 200, height: 26), pullsDown: false)
        popup.font = NSFont.systemFont(ofSize: 13)
        popup.addItems(withTitles: items)
        popup.selectItem(at: max(0, min(selected, items.count - 1)))
        popup.target = self
        popup.action = action
        container.addSubview(popup)

        return popup
    }

    // MARK: - Actions (Basic - Encoding)

    private func notifyEngineConfigChanged() {
        NotificationCenter.default.post(name: .hangeWubiConfigChanged, object: nil)
    }

    @objc private func autoCommitUnique4Changed(_ sender: NSButton) {
        HangeWubiSettings.shared.autoCommitUnique4 = sender.state == .on
        debugLog("Setting autoCommitUnique4 = \(sender.state == .on)")
        notifyEngineConfigChanged()
    }

    @objc private func autoCommitFirst5Changed(_ sender: NSButton) {
        HangeWubiSettings.shared.autoCommitFirst5 = sender.state == .on
        debugLog("Setting autoCommitFirst5 = \(sender.state == .on)")
        notifyEngineConfigChanged()
    }

    @objc private func progressiveHintChanged(_ sender: NSButton) {
        HangeWubiSettings.shared.progressiveHint = sender.state == .on
        debugLog("Setting progressiveHint = \(sender.state == .on)")
    }

    @objc private func emptyCodeActionChanged(_ sender: NSPopUpButton) {
        HangeWubiSettings.shared.emptyCodeAction = sender.indexOfSelectedItem
        debugLog("Setting emptyCodeAction = \(sender.indexOfSelectedItem)")
        notifyEngineConfigChanged()
    }

    @objc private func enterKeyActionChanged(_ sender: NSPopUpButton) {
        HangeWubiSettings.shared.enterKeyAction = sender.indexOfSelectedItem
        debugLog("Setting enterKeyAction = \(sender.indexOfSelectedItem)")
        notifyEngineConfigChanged()
    }

    // MARK: - Actions (Basic - Candidates)

    @objc private func candidateLayoutChanged(_ sender: NSPopUpButton) {
        HangeWubiSettings.shared.candidateLayout = sender.indexOfSelectedItem
        debugLog("Setting candidateLayout = \(sender.indexOfSelectedItem)")
    }

    @objc private func secondThirdSelectKeyChanged(_ sender: NSPopUpButton) {
        HangeWubiSettings.shared.secondThirdSelectKey = sender.indexOfSelectedItem
        debugLog("Setting secondThirdSelectKey = \(sender.indexOfSelectedItem)")
    }

    @objc private func candidateCountChanged(_ sender: NSPopUpButton) {
        HangeWubiSettings.shared.candidateCount = sender.indexOfSelectedItem
        debugLog("Setting candidateCount = \(sender.indexOfSelectedItem)")
        notifyEngineConfigChanged()
    }

    @objc private func plusMinusPageFlipChanged(_ sender: NSButton) {
        HangeWubiSettings.shared.plusMinusPageFlip = sender.state == .on
        debugLog("Setting plusMinusPageFlip = \(sender.state == .on)")
    }

    // MARK: - Actions (Basic - Mode Toggle)

    @objc private func toggleChineseEnglishChanged(_ sender: NSPopUpButton) {
        HangeWubiSettings.shared.toggleChineseEnglish = sender.indexOfSelectedItem
        debugLog("Setting toggleChineseEnglish = \(sender.indexOfSelectedItem)")
    }

    @objc private func showModeIndicatorChanged(_ sender: NSButton) {
        HangeWubiSettings.shared.showModeIndicator = sender.state == .on
        debugLog("Setting showModeIndicator = \(sender.state == .on)")
    }

    // MARK: - Actions (Theme)

    @objc private func candidateFontSizeChanged(_ sender: NSPopUpButton) {
        HangeWubiSettings.shared.candidateFontSize = sender.indexOfSelectedItem
        debugLog("Setting candidateFontSize = \(sender.indexOfSelectedItem)")
    }

    @objc private func firstCandidateColorChanged(_ sender: NSPopUpButton) {
        HangeWubiSettings.shared.firstCandidateColor = sender.indexOfSelectedItem
        debugLog("Setting firstCandidateColor = \(sender.indexOfSelectedItem)")
    }

    // MARK: - Actions (About)

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/VoldemortGin/hangewubi") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Refresh & Show

    private func refreshControlStates() {
        let s = HangeWubiSettings.shared
        autoCommitUnique4Check.state = s.autoCommitUnique4 ? .on : .off
        autoCommitFirst5Check.state = s.autoCommitFirst5 ? .on : .off
        progressiveHintCheck.state = s.progressiveHint ? .on : .off
        emptyCodePopup.selectItem(at: s.emptyCodeAction)
        enterKeyPopup.selectItem(at: s.enterKeyAction)
        candidateLayoutPopup.selectItem(at: s.candidateLayout)
        secondThirdSelectPopup.selectItem(at: s.secondThirdSelectKey)
        candidateCountPopup.selectItem(at: s.candidateCount)
        plusMinusPageFlipCheck.state = s.plusMinusPageFlip ? .on : .off
        toggleChineseEnglishPopup.selectItem(at: s.toggleChineseEnglish)
        showModeIndicatorCheck.state = s.showModeIndicator ? .on : .off
        candidateFontSizePopup.selectItem(at: s.candidateFontSize)
        firstCandidateColorPopup.selectItem(at: s.firstCandidateColor)
    }

    func showWindow() {
        refreshControlStates()
        self.center()
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Candidate Window

/// 自定义候选词窗口（支持横排/纵排，从设置读取字体大小、颜色等）
class CandidateWindow: NSPanel {
    static let shared = CandidateWindow()

    private let containerView = NSView()
    private let padding: CGFloat = 10
    private let cornerRadius: CGFloat = 6

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        self.level = .popUpMenu
        self.isFloatingPanel = true
        self.hasShadow = true
        self.isOpaque = false
        self.backgroundColor = .clear

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        containerView.layer?.cornerRadius = cornerRadius
        containerView.layer?.borderColor = NSColor.separatorColor.cgColor
        containerView.layer?.borderWidth = 0.5
        containerView.autoresizingMask = [.width, .height]
        self.contentView = containerView
    }

    private func firstCandidateNSColor() -> NSColor {
        switch HangeWubiSettings.shared.firstCandidateColor {
        case 0: return NSColor(calibratedRed: 0.25, green: 0.52, blue: 0.85, alpha: 1.0)
        case 1: return NSColor.systemRed
        case 2: return NSColor.systemGreen
        case 3: return NSColor.controlAccentColor
        default: return NSColor(calibratedRed: 0.25, green: 0.52, blue: 0.85, alpha: 1.0)
        }
    }

    func show(candidates: [String], code: String, near cursorRect: NSRect) {
        containerView.subviews.forEach { $0.removeFromSuperview() }

        if candidates.isEmpty {
            hide()
            return
        }

        let settings = HangeWubiSettings.shared
        let fontSize = settings.candidateFontSizeValue
        let codeFontSize = fontSize - 2
        let maxCandidates = settings.candidateCountValue
        let isVertical = settings.candidateLayout == 1
        let count = min(candidates.count, maxCandidates)
        let highlightColor = firstCandidateNSColor()

        // 编码标签
        let codeLabel = NSTextField(labelWithString: code)
        codeLabel.font = NSFont.systemFont(ofSize: codeFontSize)
        codeLabel.textColor = .labelColor
        codeLabel.isBezeled = false
        codeLabel.isEditable = false
        codeLabel.sizeToFit()
        codeLabel.frame.origin = NSPoint(x: padding, y: 0)
        containerView.addSubview(codeLabel)

        if isVertical {
            // 纵向排列：编码在最上面，每个候选词占一行
            let candidateLineHeight = fontSize * 1.4
            var maxWidth = codeLabel.frame.width

            // 先计算最大宽度
            for i in 0..<count {
                let numStr = "\(i + 1). "
                let testNum = NSTextField(labelWithString: numStr)
                testNum.font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
                testNum.sizeToFit()
                let testText = NSTextField(labelWithString: candidates[i])
                testText.font = NSFont.systemFont(ofSize: fontSize)
                testText.sizeToFit()
                let lineWidth = testNum.frame.width + testText.frame.width
                maxWidth = max(maxWidth, lineWidth)
            }

            let totalWidth = maxWidth + padding * 2
            let codeLineHeight = codeLabel.frame.height
            let totalHeight = padding + codeLineHeight + 4 + candidateLineHeight * CGFloat(count) + padding

            // 从底部开始排列候选词
            for i in 0..<count {
                let rowIndex = count - 1 - i
                let rowY = padding + candidateLineHeight * CGFloat(rowIndex)

                let numStr = "\(i + 1). "
                let numLabel = NSTextField(labelWithString: numStr)
                numLabel.font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
                numLabel.textColor = .secondaryLabelColor
                numLabel.isBezeled = false
                numLabel.isEditable = false
                numLabel.sizeToFit()
                numLabel.frame.origin = NSPoint(x: padding, y: rowY + (candidateLineHeight - numLabel.frame.height) / 2)
                containerView.addSubview(numLabel)

                let textLabel = NSTextField(labelWithString: candidates[i])
                textLabel.font = NSFont.systemFont(ofSize: fontSize)
                textLabel.textColor = i == 0 ? highlightColor : .labelColor
                textLabel.isBezeled = false
                textLabel.isEditable = false
                textLabel.sizeToFit()
                textLabel.frame.origin = NSPoint(x: padding + numLabel.frame.width, y: rowY + (candidateLineHeight - textLabel.frame.height) / 2)
                containerView.addSubview(textLabel)
            }

            // 编码放在最上面
            let codeY = padding + candidateLineHeight * CGFloat(count) + 4
            codeLabel.frame.origin.y = codeY

            // 屏幕边界检测
            let screen = NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            let screenMargin: CGFloat = 8

            var originX = cursorRect.origin.x
            if originX + totalWidth > screenFrame.maxX - screenMargin {
                originX = screenFrame.maxX - screenMargin - totalWidth
            }
            originX = max(screenFrame.origin.x + screenMargin, originX)

            var originY = cursorRect.origin.y - totalHeight - 4
            if originY < screenFrame.origin.y + screenMargin {
                originY = cursorRect.origin.y + cursorRect.size.height + 4
            }

            self.setFrame(NSRect(x: originX, y: originY, width: totalWidth, height: totalHeight),
                          display: true)
        } else {
            // 横向排列
            var xOffset: CGFloat = padding
            let candidateSpacing: CGFloat = 12

            for i in 0..<count {
                let numStr = "\(i + 1). "
                let numLabel = NSTextField(labelWithString: numStr)
                numLabel.font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
                numLabel.textColor = .secondaryLabelColor
                numLabel.isBezeled = false
                numLabel.isEditable = false
                numLabel.sizeToFit()
                numLabel.frame.origin = NSPoint(x: xOffset, y: 0)
                containerView.addSubview(numLabel)

                xOffset += numLabel.frame.width

                let textLabel = NSTextField(labelWithString: candidates[i])
                textLabel.font = NSFont.systemFont(ofSize: fontSize)
                textLabel.textColor = i == 0 ? highlightColor : .labelColor
                textLabel.isBezeled = false
                textLabel.isEditable = false
                textLabel.sizeToFit()
                textLabel.frame.origin = NSPoint(x: xOffset, y: 0)
                containerView.addSubview(textLabel)

                xOffset += textLabel.frame.width + candidateSpacing
            }

            let totalWidth = max(xOffset + padding - candidateSpacing, codeLabel.frame.width + padding * 2)
            let codeLineHeight = codeLabel.frame.height
            let candidateLineHeight = fontSize * 1.4
            let totalHeight = padding + codeLineHeight + 4 + candidateLineHeight + padding

            let candidateY = padding
            let codeY = padding + candidateLineHeight + 4

            codeLabel.frame.origin.y = codeY

            for view in containerView.subviews where view !== codeLabel {
                var frame = view.frame
                frame.origin.y = candidateY + (candidateLineHeight - frame.height) / 2
                view.frame = frame
            }

            // 屏幕边界检测
            let screen = NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            let screenMargin: CGFloat = 8

            // X: 如果超出屏幕右边，则往左推
            var originX = cursorRect.origin.x
            if originX + totalWidth > screenFrame.maxX - screenMargin {
                originX = screenFrame.maxX - screenMargin - totalWidth
            }
            originX = max(screenFrame.origin.x + screenMargin, originX)

            // Y: 优先在光标下方，如果超出屏幕底部则放到光标上方
            var originY = cursorRect.origin.y - totalHeight - 4
            if originY < screenFrame.origin.y + screenMargin {
                // 放到光标上方
                originY = cursorRect.origin.y + cursorRect.size.height + 4
            }

            self.setFrame(NSRect(x: originX, y: originY, width: totalWidth, height: totalHeight),
                          display: true)
        }

        self.orderFront(nil)
    }

    func hide() {
        self.orderOut(nil)
    }
}

// MARK: - Mode Indicator Window

class ModeIndicatorWindow: NSPanel {
    static let shared = ModeIndicatorWindow()
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 36, height: 36),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        self.level = .popUpMenu
        self.isFloatingPanel = true
        self.hasShadow = true
        self.isOpaque = false
        self.backgroundColor = .clear

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 6
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.borderWidth = 0.5
        self.contentView = container

        label.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        label.alignment = .center
        label.isBezeled = false
        label.isEditable = false
        label.frame = NSRect(x: 0, y: 4, width: 36, height: 28)
        container.addSubview(label)
    }

    func show(text: String, near cursorRect: NSRect) {
        hideTimer?.invalidate()
        label.stringValue = text
        label.textColor = .labelColor
        let origin = NSPoint(x: cursorRect.origin.x - 44,
                             y: cursorRect.origin.y - 40)
        self.setFrame(NSRect(x: origin.x, y: origin.y, width: 36, height: 36), display: true)
        self.alphaValue = 1.0
        self.orderFront(nil)

        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                self?.animator().alphaValue = 0.0
            }, completionHandler: {
                self?.orderOut(nil)
                self?.alphaValue = 1.0
            })
        }
    }
}

// MARK: - Input Controller

/// 晗戈五笔 macOS 输入法控制器
/// 通过 C FFI 调用 Rust 引擎
@objc(InputController)
class InputController: IMKInputController {

    // Shift toggle tracking
    private var shiftPressed = false

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        debugLog("InputController.init 被调用")

        // 初始化 Rust 引擎
        let bundlePath = Bundle.main.resourcePath ?? ""
        let dictPath = "\(bundlePath)/data/wubi86.txt"
        debugLog("码表路径: \(dictPath)")
        let count = ffi_init(dictPath)
        if count < 0 {
            debugLog("码表加载失败: \(dictPath)")
        } else {
            debugLog("已加载 \(count) 条词条")
        }

        syncConfigToEngine()

        NotificationCenter.default.addObserver(self, selector: #selector(handleConfigChanged),
                                               name: .hangeWubiConfigChanged, object: nil)
    }

    @objc private func handleConfigChanged() {
        syncConfigToEngine()
    }

    /// Sync all relevant settings to the Rust engine config
    func syncConfigToEngine() {
        let s = HangeWubiSettings.shared
        ffi_set_config(
            s.autoCommitUnique4,
            s.autoCommitFirst5,
            UInt8(s.enterKeyAction),
            UInt8(s.emptyCodeAction),
            UInt8(s.candidateCountValue),
            false // macOS 暂不启用拼音混输
        )
        debugLog("syncConfigToEngine: unique4=\(s.autoCommitUnique4) first5=\(s.autoCommitFirst5) enter=\(s.enterKeyAction) empty=\(s.emptyCodeAction) count=\(s.candidateCountValue)")
    }

    // MARK: - Menu

    override func menu() -> NSMenu! {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(openPreferences(_:)), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "关于晗戈五笔", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        return menu
    }

    @objc private func openPreferences(_ sender: Any?) {
        PreferencesWindow.shared.showWindow()
    }

    @objc private func showAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "晗戈五笔"
        alert.informativeText = "版本 0.1.0\n基于 Rust 引擎的五笔输入法"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    // MARK: - Activation / Deactivation

    override func activateServer(_ sender: Any!) {
        debugLog("activateServer")
    }

    override func deactivateServer(_ sender: Any!) {
        debugLog("deactivateServer")
        let _ = ffi_handle_escape()
        if let client = sender as? IMKTextInput {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        hideCandidates()
    }

    // MARK: - Event Handling

    override func recognizedEvents(_ sender: Any!) -> Int {
        let events: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        return Int(events.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, let client = sender as? IMKTextInput else {
            debugLog("handle: event 或 client 为 nil")
            return false
        }

        let keyCode = event.keyCode
        let modifiers = event.modifierFlags
        debugLog("handle: keyCode=\(keyCode) type=\(event.type.rawValue) modifiers=\(modifiers.rawValue)")

        // Handle flagsChanged events for Shift toggle
        if event.type == .flagsChanged {
            return handleFlagsChanged(event: event, client: client)
        }

        // Any keyDown event means Shift is being used as a modifier, not standalone
        shiftPressed = false

        let chars = event.characters ?? ""
        debugLog("handle: keyCode=\(keyCode) chars='\(chars)' type=\(event.type.rawValue)")

        // 有 Cmd/Ctrl/Option 修饰键的不处理
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
            return false
        }

        let settings = HangeWubiSettings.shared
        let result: FfiResult

        // Backspace must be checked BEFORE character-based switch,
        // because backspace produces \u{7F} (DEL) which is non-empty
        // and would fall through to the default branch otherwise.
        if keyCode == 51 {
            result = ffi_handle_backspace()
        } else if let ch = chars.first {
            switch ch {
            case " ":
                result = ffi_handle_space()
            case "\r", "\n":
                result = ffi_handle_enter()
            case "\u{1B}":  // Escape
                result = ffi_handle_escape()
            case ";":
                if settings.semicolonSelectSecond {
                    result = ffi_handle_semicolon()
                } else {
                    // Treat as punctuation when disabled
                    let mode = ffi_get_mode()
                    let bufPtr = ffi_get_buffer()
                    let buf = bufPtr.flatMap { String(cString: $0) } ?? ""
                    if let ptr = bufPtr { ffi_free_string(ptr) }
                    if !buf.isEmpty && mode != 1 {
                        // In Chinese mode with buffer, pass as punctuation
                        result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue!))
                    } else {
                        return false
                    }
                }
            case "'":
                // 单引号：编码非空时选第三候选，否则作为标点
                let mode = ffi_get_mode()
                let bufPtr = ffi_get_buffer()
                let buf = bufPtr.flatMap { String(cString: $0) } ?? ""
                if let ptr = bufPtr { ffi_free_string(ptr) }
                if !buf.isEmpty && mode != 1 && settings.quoteSelectThird {
                    result = ffi_handle_quote()
                } else if !buf.isEmpty && mode != 1 {
                    // Feature disabled but buffer non-empty: treat as punctuation
                    result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue!))
                } else {
                    result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue!))
                }
            case "=", "+":
                // 翻页下一页：编码非空时翻页，否则放行
                let bufPtr2 = ffi_get_buffer()
                let buf2 = bufPtr2.flatMap { String(cString: $0) } ?? ""
                if let ptr = bufPtr2 { ffi_free_string(ptr) }
                if !buf2.isEmpty && settings.plusEqualsNextPage {
                    result = ffi_next_page()
                } else {
                    return false
                }
            case "-":
                // 翻页上一页：编码非空时翻页，否则放行
                let bufPtr3 = ffi_get_buffer()
                let buf3 = bufPtr3.flatMap { String(cString: $0) } ?? ""
                if let ptr = bufPtr3 { ffi_free_string(ptr) }
                if !buf3.isEmpty && settings.minusPrevPage {
                    result = ffi_prev_page()
                } else {
                    return false
                }
            case "1"..."9":
                let num = UInt8(ch.asciiValue! - 48)
                result = ffi_handle_number(num)
            case "a"..."z", "A"..."Z":
                result = ffi_handle_key(Int8(bitPattern: ch.asciiValue!))
            default:
                if ch.isPunctuation || ",.?!:@#$%^&*-_+=~\\\"'()[]{}<>".contains(ch) {
                    result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue ?? 0))
                } else {
                    return false
                }
            }
        } else {
            return false
        }

        debugLog("handle: result.action=\(result.action)")

        // 处理引擎返回的动作
        switch result.action {
        case FFI_ACTION_COMMIT:
            if let text = result.text {
                let str = String(cString: text)
                client.insertText(str, replacementRange: NSRange(location: NSNotFound, length: 0))
                ffi_free_string(text)
            }
            updateMarkedText(client: client)
            return true

        case FFI_ACTION_UPDATE_CANDIDATES:
            updateMarkedText(client: client)
            return true

        case FFI_ACTION_RESET:
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            hideCandidates()
            return true

        case FFI_ACTION_UNHANDLED:
            return false

        default:
            return false
        }
    }

    // MARK: - Shift Toggle via flagsChanged

    private func handleFlagsChanged(event: NSEvent, client: IMKTextInput) -> Bool {
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags

        // Shift key codes: 56 (left), 60 (right)
        let isShiftKey = keyCode == 56 || keyCode == 60

        if !isShiftKey {
            // Some other modifier changed, cancel shift tracking
            shiftPressed = false
            return false
        }

        let shiftIsDown = modifiers.contains(.shift)

        if shiftIsDown {
            // Shift just pressed down - only track if no other modifiers held
            let otherModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
            if modifiers.isDisjoint(with: otherModifiers) {
                shiftPressed = true
                debugLog("Shift pressed down (tracking)")
            } else {
                shiftPressed = false
            }
        } else {
            // Shift released
            if shiftPressed && HangeWubiSettings.shared.shiftToggleEnabled {
                debugLog("Shift released alone - toggling mode")
                // 把已输入的编码作为英文直接上屏，然后切换模式
                let bufPtr = ffi_get_buffer()
                let buf = bufPtr.flatMap { String(cString: $0) } ?? ""
                if let ptr = bufPtr { ffi_free_string(ptr) }
                if !buf.isEmpty {
                    // 先上屏英文
                    client.insertText(buf, replacementRange: NSRange(location: NSNotFound, length: 0))
                    // 再清除引擎状态
                    let _ = ffi_handle_escape()
                    client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
                    hideCandidates()
                }
                ffi_toggle_mode()
                // Show mode indicator if enabled
                if HangeWubiSettings.shared.showModeIndicator {
                    let mode = ffi_get_mode()
                    let indicator = mode == 0 ? "中" : "英"
                    var cursorRect = NSRect.zero
                    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &cursorRect)
                    ModeIndicatorWindow.shared.show(text: indicator, near: cursorRect)
                }
                shiftPressed = false
                return true
            }
            shiftPressed = false
        }

        return false
    }

    // MARK: - Candidate Management

    private func updateMarkedText(client: IMKTextInput) {
        let bufferPtr = ffi_get_buffer()
        let buffer = bufferPtr.flatMap { String(cString: $0) } ?? ""
        if let ptr = bufferPtr { ffi_free_string(ptr) }

        if buffer.isEmpty {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            hideCandidates()
        } else {
            client.setMarkedText(buffer, selectionRange: NSRange(location: buffer.count, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))

            // Get candidates from FFI
            let candidateStrings = getCandidateStrings()

            if candidateStrings.isEmpty {
                hideCandidates()
            } else {
                // Get cursor position from client
                var lineHeightRect = NSRect.zero
                client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineHeightRect)
                debugLog("updateMarkedText: cursorRect=\(lineHeightRect) candidates=\(candidateStrings.count)")

                CandidateWindow.shared.show(candidates: candidateStrings, code: buffer, near: lineHeightRect)
            }

            // Also try IMKCandidates as fallback
            sharedCandidates?.update()
        }
    }

    private func hideCandidates() {
        CandidateWindow.shared.hide()
        sharedCandidates?.hide()
    }

    private func getCandidateStrings() -> [String] {
        let list = ffi_get_candidates()
        var result: [String] = []

        if list.count > 0, let candidates = list.candidates {
            for i in 0..<list.count {
                let candidate = candidates[i]
                if let text = candidate.text {
                    let str = String(cString: text)
                    if let code = candidate.code {
                        let codeStr = String(cString: code)
                        result.append("\(str) [\(codeStr)]")
                    } else {
                        result.append(str)
                    }
                }
            }
        }
        ffi_free_candidate_list(list)

        return result
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        let list = ffi_get_candidates()
        var result: [String] = []

        if list.count > 0, let candidates = list.candidates {
            for i in 0..<list.count {
                let candidate = candidates[i]
                if let text = candidate.text {
                    let str = String(cString: text)
                    if let code = candidate.code {
                        let codeStr = String(cString: code)
                        result.append("\(i + 1). \(str) [\(codeStr)]")
                    } else {
                        result.append("\(i + 1). \(str)")
                    }
                }
            }
        }
        ffi_free_candidate_list(list)

        return result
    }
}
