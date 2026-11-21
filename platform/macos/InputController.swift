import Cocoa
import InputMethodKit
import os.log

private let logger = OSLog(subsystem: "com.hangewubi.inputmethod.HangeWubi", category: "InputController")

private func debugLog(_ message: @autoclosure () -> String) {
    // release 下整段跳过，@autoclosure 保证实参插值字符串不被求值（消除热路径开销）
    #if DEBUG
    let message = message()
    os_log("%{public}@", log: logger, type: .default, message)
    // 同时写文件日志（仅 DEBUG 构建，避免 release 热路径同步写盘）
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
    #endif
}

/// 「关于」页版本文字：读 Info.plist；包内无拼音数据（纯五笔版）时加后缀
private func appVersionText() -> String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    return ffi_has_pinyin() ? version : "\(version)（纯五笔版）"
}

// MARK: - Notifications

extension Notification.Name {
    static let hangeWubiConfigChanged = Notification.Name("hangeWubiConfigChanged")
    static let hangeWubiUserDictChanged = Notification.Name("hangeWubiUserDictChanged")
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
            "pinyinMixedEnabled": false,
            "commonCharsOnly": false,
            "autoPhrase": false,
            "association": false,
            "traditionalOutput": false,
            "emptyCodeAction": 0,
            "enterKeyAction": 0,
            // Basic - Candidates
            "candidateLayout": 0,
            "secondThirdSelectKey": 0,
            "candidateCount": 2,
            "plusMinusPageFlip": true,
            "commaPeriodPageFlip": false,
            "bracketPageFlip": false,
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

    var pinyinMixedEnabled: Bool {
        get { defaults.bool(forKey: "pinyinMixedEnabled") }
        set { defaults.set(newValue, forKey: "pinyinMixedEnabled") }
    }

    var commonCharsOnly: Bool {
        get { defaults.bool(forKey: "commonCharsOnly") }
        set { defaults.set(newValue, forKey: "commonCharsOnly") }
    }

    var autoPhrase: Bool {
        get { defaults.bool(forKey: "autoPhrase") }
        set { defaults.set(newValue, forKey: "autoPhrase") }
    }

    var association: Bool {
        get { defaults.bool(forKey: "association") }
        set { defaults.set(newValue, forKey: "association") }
    }

    /// 繁体输出（菜单 / Ctrl+Shift+F 切换，非设置界面项；仅为跨重启持久化）
    var traditionalOutput: Bool {
        get { defaults.bool(forKey: "traditionalOutput") }
        set { defaults.set(newValue, forKey: "traditionalOutput") }
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

    var commaPeriodPageFlip: Bool {
        get { defaults.bool(forKey: "commaPeriodPageFlip") }
        set { defaults.set(newValue, forKey: "commaPeriodPageFlip") }
    }

    var bracketPageFlip: Bool {
        get { defaults.bool(forKey: "bracketPageFlip") }
        set { defaults.set(newValue, forKey: "bracketPageFlip") }
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

    var semicolonSelectSecond: Bool {
        get { secondThirdSelectKey == 0 }
        set { secondThirdSelectKey = newValue ? 0 : 2 }
    }

    var quoteSelectThird: Bool {
        get { secondThirdSelectKey == 0 }
        set { secondThirdSelectKey = newValue ? 0 : 2 }
    }

    /// `[ ]` 选二三候选（与「[ ] 翻页」互斥，由设置界面保证）
    var bracketSelectSecondThird: Bool {
        secondThirdSelectKey == 1
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

class PreferencesWindow: NSWindow, NSTabViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let shared = PreferencesWindow()

    private var tabView: NSTabView!

    // Controls that need state refresh
    private var autoCommitUnique4Check: NSButton!
    private var autoCommitFirst5Check: NSButton!
    private var progressiveHintCheck: NSButton!
    private var pinyinMixedEnabledCheck: NSButton!
    private var commonCharsOnlyCheck: NSButton!
    private var autoPhraseCheck: NSButton!
    private var associationCheck: NSButton!
    private var emptyCodePopup: NSPopUpButton!
    private var enterKeyPopup: NSPopUpButton!
    private var candidateLayoutPopup: NSPopUpButton!
    private var secondThirdSelectPopup: NSPopUpButton!
    private var candidateCountPopup: NSPopUpButton!
    private var plusMinusPageFlipCheck: NSButton!
    private var commaPeriodPageFlipCheck: NSButton!
    private var bracketPageFlipCheck: NSButton!
    private var toggleChineseEnglishPopup: NSPopUpButton!
    private var showModeIndicatorCheck: NSButton!
    private var candidateFontSizePopup: NSPopUpButton!
    private var firstCandidateColorPopup: NSPopUpButton!

    // 用户词库页：列表数据来自引擎（ffi_list_custom_words），本地只做展示缓存
    private var userWordsTable: NSTableView!
    private var userWordField: NSTextField!
    private var userWordPreviewLabel: NSTextField!
    private var userWordStatusLabel: NSTextField!
    private var userWords: [(text: String, code: String)] = []

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

        // Tab 3: User Dict
        let userDictTab = NSTabViewItem(identifier: "userDict")
        userDictTab.label = "用户词库"
        if let img = NSImage(systemSymbolName: "book", accessibilityDescription: "用户词库") {
            userDictTab.image = img
        }
        userDictTab.view = buildUserDictTab()
        tabView.addTabViewItem(userDictTab)

        // Tab 4: About
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

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 730))
        scrollView.documentView = contentView

        let settings = HangeWubiSettings.shared
        var y: CGFloat = 730

        // --- Section: 编码 ---
        y -= 10
        y = addSectionBox(to: contentView, title: "编码", y: y, height: 302) { box, startY in
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

            self.pinyinMixedEnabledCheck = self.addCheckbox(
                to: box, title: "启用拼音混输", y: &innerY,
                checked: settings.pinyinMixedEnabled, action: #selector(self.pinyinMixedEnabledChanged(_:)))

            self.commonCharsOnlyCheck = self.addCheckbox(
                to: box, title: "仅显示常用字（GB2312）", y: &innerY,
                checked: settings.commonCharsOnly, action: #selector(self.commonCharsOnlyChanged(_:)))

            self.autoPhraseCheck = self.addCheckbox(
                to: box, title: "自动造词（连续逐字输入的词第二次出现时加入用户词库）", y: &innerY,
                checked: settings.autoPhrase, action: #selector(self.autoPhraseChanged(_:)))

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
        y = addSectionBox(to: contentView, title: "候选词", y: y, height: 270) { box, startY in
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
                to: box, title: "使用 +/= 和 - 键翻页", y: &innerY,
                checked: settings.plusMinusPageFlip, action: #selector(self.plusMinusPageFlipChanged(_:)))

            self.commaPeriodPageFlipCheck = self.addCheckbox(
                to: box, title: "使用 , 和 . 键翻页", y: &innerY,
                checked: settings.commaPeriodPageFlip, action: #selector(self.commaPeriodPageFlipChanged(_:)))

            self.bracketPageFlipCheck = self.addCheckbox(
                to: box, title: "使用 [ 和 ] 键翻页（与 [ ] 选二三候选互斥）", y: &innerY,
                checked: settings.bracketPageFlip, action: #selector(self.bracketPageFlipChanged(_:)))

            self.associationCheck = self.addCheckbox(
                to: box, title: "词语联想（上屏后候选显示以其开头的词，数字键选取）", y: &innerY,
                checked: settings.association, action: #selector(self.associationChanged(_:)))
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

    // MARK: - User Dict Tab

    private func buildUserDictTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 510))

        // 输入行：词 + 添加按钮
        let field = NSTextField(frame: NSRect(x: 20, y: 456, width: 360, height: 24))
        field.placeholderString = "输入要添加的词（全部为汉字）"
        field.font = NSFont.systemFont(ofSize: 13)
        field.delegate = self
        field.target = self
        field.action = #selector(addUserWord(_:))
        view.addSubview(field)
        userWordField = field

        let addButton = NSButton(title: "添加", target: self, action: #selector(addUserWord(_:)))
        addButton.bezelStyle = .rounded
        addButton.frame = NSRect(x: 388, y: 453, width: 80, height: 30)
        view.addSubview(addButton)

        // 编码预览 / 结果提示
        let preview = NSTextField(labelWithString: "编码：")
        preview.font = NSFont.systemFont(ofSize: 12)
        preview.textColor = .secondaryLabelColor
        preview.frame = NSRect(x: 20, y: 428, width: 260, height: 18)
        view.addSubview(preview)
        userWordPreviewLabel = preview

        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 12)
        status.frame = NSRect(x: 280, y: 428, width: 300, height: 18)
        view.addSubview(status)
        userWordStatusLabel = status

        // 列表：词 / 编码两列
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        for (id, title, width) in [("text", "词", CGFloat(330)), ("code", "编码", CGFloat(160))] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        userWordsTable = table

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 56, width: 540, height: 362))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        view.addSubview(scroll)

        let deleteButton = NSButton(title: "删除选中", target: self, action: #selector(deleteUserWord(_:)))
        deleteButton.bezelStyle = .rounded
        deleteButton.frame = NSRect(x: 20, y: 16, width: 100, height: 30)
        view.addSubview(deleteButton)

        return view
    }

    /// 从引擎重新拉取全部自造词（JSON 数组 [{"text","code"}]）并刷新列表
    private func reloadUserWords() {
        var words: [(text: String, code: String)] = []
        if let ptr = ffi_list_custom_words() {
            let json = String(cString: ptr)
            ffi_free_string(ptr)
            if let data = json.data(using: .utf8),
               let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] {
                words = items.compactMap { item in
                    guard let text = item["text"], let code = item["code"] else { return nil }
                    return (text, code)
                }
            }
        }
        userWords = words
        userWordsTable?.reloadData()
    }

    private func updateUserWordPreview() {
        let word = userWordField.stringValue.trimmingCharacters(in: .whitespaces)
        userWordStatusLabel.stringValue = ""
        guard !word.isEmpty else {
            userWordPreviewLabel.stringValue = "编码："
            return
        }
        let code: String? = word.withCString { cWord in
            guard let ptr = ffi_preview_word_code(cWord) else { return nil }
            defer { ffi_free_string(ptr) }
            return String(cString: ptr)
        }
        userWordPreviewLabel.stringValue = "编码：" + (code ?? "（无法编码）")
    }

    /// 增删后通知输入控制器落盘用户词典
    private func notifyUserDictChanged() {
        NotificationCenter.default.post(name: .hangeWubiUserDictChanged, object: nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        updateUserWordPreview()
    }

    @objc private func addUserWord(_ sender: Any?) {
        let word = userWordField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        let rc = word.withCString { ffi_add_custom_word($0) }
        switch rc {
        case 0:
            userWordField.stringValue = ""
            updateUserWordPreview()
            userWordStatusLabel.textColor = .secondaryLabelColor
            userWordStatusLabel.stringValue = "已添加：\(word)"
            reloadUserWords()
            notifyUserDictChanged()
        case 1:
            userWordStatusLabel.textColor = .systemRed
            userWordStatusLabel.stringValue = "无法编码（须全为码表中有编码的汉字）"
        case 2:
            userWordStatusLabel.textColor = .systemRed
            userWordStatusLabel.stringValue = "已存在（码表或用户词库中已有该词）"
        default:
            userWordStatusLabel.textColor = .systemRed
            userWordStatusLabel.stringValue = "添加失败（引擎未就绪）"
        }
        debugLog("addUserWord \(word) -> \(rc)")
    }

    @objc private func deleteUserWord(_ sender: Any?) {
        let row = userWordsTable.selectedRow
        guard row >= 0 && row < userWords.count else { return }
        let entry = userWords[row]
        let removed = entry.text.withCString { cText in
            entry.code.withCString { cCode in ffi_remove_custom_word(cText, cCode) }
        }
        debugLog("deleteUserWord \(entry.text) \(entry.code) -> \(removed)")
        reloadUserWords()
        if removed {
            notifyUserDictChanged()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        userWords.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < userWords.count else { return nil }
        let id = column.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = id
            label.font = NSFont.systemFont(ofSize: 13)
            return label
        }()
        cell.stringValue = id.rawValue == "text" ? userWords[row].text : userWords[row].code
        return cell
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if (tabViewItem?.identifier as? String) == "userDict" {
            reloadUserWords()
        }
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
        let versionLabel = NSTextField(labelWithString: "版本 \(appVersionText())")
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
        notifyEngineConfigChanged()
    }

    @objc private func pinyinMixedEnabledChanged(_ sender: NSButton) {
        HangeWubiSettings.shared.pinyinMixedEnabled = sender.state == .on
        debugLog("Setting pinyinMixedEnabled = \(sender.state == .on)")
        notifyEngineConfigChanged()
    }

    @objc private func commonCharsOnlyChanged(_ sender: NSButton) {
        HangeWubiSettings.shared.commonCharsOnly = sender.state == .on
        debugLog("Setting commonCharsOnly = \(sender.state == .on)")
        notifyEngineConfigChanged()
    }

    @objc private func autoPhraseChanged(_ sender: NSButton) {
        HangeWubiSettings.shared.autoPhrase = sender.state == .on
        debugLog("Setting autoPhrase = \(sender.state == .on)")
        notifyEngineConfigChanged()
    }

    @objc private func associationChanged(_ sender: NSButton) {
        HangeWubiSettings.shared.association = sender.state == .on
        debugLog("Setting association = \(sender.state == .on)")
        notifyEngineConfigChanged()
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
        let settings = HangeWubiSettings.shared
        settings.secondThirdSelectKey = sender.indexOfSelectedItem
        // `[ ]` 选二三候选与 `[ ]` 翻页互斥：选了前者就关掉后者
        if settings.bracketSelectSecondThird && settings.bracketPageFlip {
            settings.bracketPageFlip = false
            bracketPageFlipCheck.state = .off
        }
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

    @objc private func commaPeriodPageFlipChanged(_ sender: NSButton) {
        HangeWubiSettings.shared.commaPeriodPageFlip = sender.state == .on
        debugLog("Setting commaPeriodPageFlip = \(sender.state == .on)")
    }

    @objc private func bracketPageFlipChanged(_ sender: NSButton) {
        let settings = HangeWubiSettings.shared
        settings.bracketPageFlip = sender.state == .on
        // 与 `[ ]` 选二三候选互斥：开启翻页时把额外选择键恢复为默认的 `; '`
        if settings.bracketPageFlip && settings.bracketSelectSecondThird {
            settings.secondThirdSelectKey = 0
            secondThirdSelectPopup.selectItem(at: 0)
        }
        debugLog("Setting bracketPageFlip = \(sender.state == .on)")
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
        // 纯五笔版（包内无拼音数据）：拼音混输不可用，置灰并说明
        let hasPinyin = ffi_has_pinyin()
        pinyinMixedEnabledCheck.state = (s.pinyinMixedEnabled && hasPinyin) ? .on : .off
        pinyinMixedEnabledCheck.isEnabled = hasPinyin
        pinyinMixedEnabledCheck.title = hasPinyin ? "启用拼音混输" : "启用拼音混输（纯五笔版不含拼音数据）"
        commonCharsOnlyCheck.state = s.commonCharsOnly ? .on : .off
        autoPhraseCheck.state = s.autoPhrase ? .on : .off
        associationCheck.state = s.association ? .on : .off
        emptyCodePopup.selectItem(at: s.emptyCodeAction)
        enterKeyPopup.selectItem(at: s.enterKeyAction)
        candidateLayoutPopup.selectItem(at: s.candidateLayout)
        secondThirdSelectPopup.selectItem(at: s.secondThirdSelectKey)
        candidateCountPopup.selectItem(at: s.candidateCount)
        plusMinusPageFlipCheck.state = s.plusMinusPageFlip ? .on : .off
        commaPeriodPageFlipCheck.state = s.commaPeriodPageFlip ? .on : .off
        bracketPageFlipCheck.state = s.bracketPageFlip ? .on : .off
        toggleChineseEnglishPopup.selectItem(at: s.toggleChineseEnglish)
        showModeIndicatorCheck.state = s.showModeIndicator ? .on : .off
        candidateFontSizePopup.selectItem(at: s.candidateFontSize)
        firstCandidateColorPopup.selectItem(at: s.firstCandidateColor)
    }

    func showWindow() {
        refreshControlStates()
        reloadUserWords()
        self.center()
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Candidate Window

/// 自定义候选词窗口（支持横排/纵排，从设置读取字体大小、颜色等）
class CandidateWindow: NSPanel {
    static let shared = CandidateWindow()

    private let containerView = NSVisualEffectView()
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

        // 用毛玻璃材质，自动跟随系统明暗，避免暗色下露白底
        containerView.material = .menu
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = cornerRadius
        containerView.layer?.masksToBounds = true
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

    /// 为首选项构造一个圆角强调色块（放在文字下方），对齐原生首选高亮
    private func highlightBlock(for label: NSTextField, color: NSColor) -> NSView {
        let padX: CGFloat = 5
        let padY: CGFloat = 2
        let frame = NSRect(x: label.frame.origin.x - padX,
                           y: label.frame.origin.y - padY,
                           width: label.frame.width + padX * 2,
                           height: label.frame.height + padY * 2)
        let block = NSView(frame: frame)
        block.wantsLayer = true
        block.layer?.backgroundColor = color.cgColor
        block.layer?.cornerRadius = 4
        return block
    }

    /// 编码提示标签：较淡、略小的字号；提示为空则不创建
    private func hintLabel(_ hint: String?, fontSize: CGFloat) -> NSTextField? {
        guard let hint = hint, !hint.isEmpty else { return nil }
        let label = NSTextField(labelWithString: hint)
        label.font = NSFont.systemFont(ofSize: fontSize * 0.7)
        label.textColor = .tertiaryLabelColor
        label.isBezeled = false
        label.isEditable = false
        label.sizeToFit()
        return label
    }

    /// hints 与 candidates 按序号平行，空串表示无提示（精确匹配）
    func show(candidates: [String], hints: [String] = [], code: String, near cursorRect: NSRect) {
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
            let codeLineHeight = codeLabel.frame.height
            let hintGap: CGFloat = 3
            let totalHeight = padding + codeLineHeight + 4 + candidateLineHeight * CGFloat(count) + padding

            // 一遍排版即顺带测量最大宽度，省去单独的预扫描测量遍（每键少建 2×count 个临时 NSTextField）
            var maxWidth = codeLabel.frame.width

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
                textLabel.textColor = i == 0 ? .white : .labelColor
                textLabel.isBezeled = false
                textLabel.isEditable = false
                textLabel.sizeToFit()
                textLabel.frame.origin = NSPoint(x: padding + numLabel.frame.width, y: rowY + (candidateLineHeight - textLabel.frame.height) / 2)
                if i == 0 {
                    containerView.addSubview(highlightBlock(for: textLabel, color: highlightColor))
                }
                containerView.addSubview(textLabel)

                var rowWidth = numLabel.frame.width + textLabel.frame.width
                if let hl = hintLabel(i < hints.count ? hints[i] : nil, fontSize: fontSize) {
                    hl.frame.origin = NSPoint(x: textLabel.frame.maxX + hintGap,
                                              y: rowY + (candidateLineHeight - hl.frame.height) / 2)
                    containerView.addSubview(hl)
                    rowWidth += hintGap + hl.frame.width
                }
                maxWidth = max(maxWidth, rowWidth)
            }

            let totalWidth = maxWidth + padding * 2

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
            let hintGap: CGFloat = 3
            var firstTextLabel: NSTextField?

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
                textLabel.textColor = i == 0 ? .white : .labelColor
                textLabel.isBezeled = false
                textLabel.isEditable = false
                textLabel.sizeToFit()
                textLabel.frame.origin = NSPoint(x: xOffset, y: 0)
                containerView.addSubview(textLabel)
                if i == 0 { firstTextLabel = textLabel }

                xOffset += textLabel.frame.width
                if let hl = hintLabel(i < hints.count ? hints[i] : nil, fontSize: fontSize) {
                    xOffset += hintGap
                    hl.frame.origin = NSPoint(x: xOffset, y: 0)
                    containerView.addSubview(hl)
                    xOffset += hl.frame.width
                }
                xOffset += candidateSpacing
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

            // 首选强调色块（在文字居中后再插入，置于首选文字下方）
            if let firstTextLabel = firstTextLabel {
                let block = highlightBlock(for: firstTextLabel, color: highlightColor)
                containerView.addSubview(block, positioned: .below, relativeTo: firstTextLabel)
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

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        container.material = .menu
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.masksToBounds = true
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
        let width = max(36, CGFloat(text.count) * 20 + 8)
        label.frame = NSRect(x: 0, y: 4, width: width, height: 28)
        let origin = NSPoint(x: cursorRect.origin.x - 44,
                             y: cursorRect.origin.y - 40)
        self.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: 36), display: true)
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

    // 用户词典落盘节流（引擎/词典为全局单例，故用类型级共享状态串行落盘）
    private static let saveQueue = DispatchQueue(label: "com.hangewubi.inputmethod.userdict.save")
    private static var userDictDirty = false
    private static var lastSaveTime = Date.distantPast
    private static let saveThrottleInterval: TimeInterval = 10

    // 用户词典只在进程内首个控制器实例加载一次，避免后续实例覆盖内存中的自学习数据
    private static var userDictLoaded = false

    /// 用户词典持久化路径：~/Library/Application Support/晗戈五笔/user_dict.json
    /// load 与 save 共用此路径；访问时确保目录存在。
    private var userDictPath: String {
        let fm = FileManager.default
        let baseDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = baseDir.appendingPathComponent("晗戈五笔", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("user_dict.json").path
    }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        debugLog("InputController.init 被调用")

        // 初始化 Rust 引擎（五笔 + 拼音混输）
        let bundlePath = Bundle.main.resourcePath ?? ""
        let dictPath = "\(bundlePath)/data/wubi86.txt"
        let pinyinPath = "\(bundlePath)/data/pinyin.txt"
        debugLog("码表路径: \(dictPath)  拼音路径: \(pinyinPath)")
        let count = ffi_init_with_pinyin(dictPath, pinyinPath)
        if count < 0 {
            debugLog("码表加载失败: \(dictPath)")
        } else {
            debugLog("已加载 \(count) 条词条")
        }

        // 加载用户词典（自造词/调频持久化）。引擎是进程内全局单例，IMK 会创建多个
        // 控制器实例；只在首个实例加载一次，避免后续实例用磁盘旧内容覆盖内存中尚未落盘的自学习数据。
        if !InputController.userDictLoaded {
            InputController.userDictLoaded = true
            let userDict = userDictPath
            let loaded = userDict.withCString { ffi_load_user_dict($0) }
            debugLog("加载用户词典: \(userDict) -> \(loaded)")
        }

        syncConfigToEngine()

        NotificationCenter.default.addObserver(self, selector: #selector(handleConfigChanged),
                                               name: .hangeWubiConfigChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleUserDictChanged),
                                               name: .hangeWubiUserDictChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .hangeWubiConfigChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .hangeWubiUserDictChanged, object: nil)
    }

    @objc private func handleConfigChanged() {
        syncConfigToEngine()
    }

    /// 设置窗口增删自造词后立即落盘（多个控制器实例都会收到，dirty 标志保证只写一次）
    @objc private func handleUserDictChanged() {
        markUserDictDirty()
        saveUserDictIfNeeded(force: true)
    }

    // MARK: - Composition Finalize / User Dict Persistence

    /// 组合被强制结束时的统一收尾（commitComposition / deactivate 共用）：
    /// 有候选则把当前页首选候选上屏，无候选则丢弃；随后清空引擎与预编辑。
    /// client 可能为 nil 或已不可写（如失焦后），此时判空兜底、直接丢弃编码。
    /// 绝不让编码字母原文进入文档。
    @discardableResult
    private func finishComposition(client: IMKTextInput?) -> Bool {
        // 联想候选不是在途编码：失焦时只取消联想，不上屏
        let candidates = ffi_is_associating() ? [] : getCandidateStrings()
        var committed = false
        if let first = candidates.first, let client = client {
            client.insertText(first, replacementRange: NSRange(location: NSNotFound, length: 0))
            committed = true
        }
        let _ = ffi_handle_escape()
        client?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))
        hideCandidates()
        return committed
    }

    /// 标记用户词典有未落盘的实际改动（在真正提交/选字后调用）。
    private func markUserDictDirty() {
        InputController.userDictDirty = true
    }

    /// 按需落盘用户词典：仅在有实际改动时保存，主线程节流，写盘放后台串行队列。
    /// force=true 时跳过节流（如失焦/退出兜底）。ffi_save_user_dict 内部有全局锁，后台调用安全。
    private func saveUserDictIfNeeded(force: Bool) {
        guard InputController.userDictDirty else { return }
        let now = Date()
        if !force && now.timeIntervalSince(InputController.lastSaveTime) < InputController.saveThrottleInterval {
            return
        }
        InputController.userDictDirty = false
        InputController.lastSaveTime = now
        let path = userDictPath
        InputController.saveQueue.async {
            let saved = path.withCString { ffi_save_user_dict($0) }
            debugLog("后台保存用户词典: \(path) -> \(saved)")
        }
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
            s.pinyinMixedEnabled && ffi_has_pinyin()
        )
        ffi_set_code_hint(s.progressiveHint)
        ffi_set_common_chars_only(s.commonCharsOnly)
        ffi_set_traditional(s.traditionalOutput)
        ffi_set_auto_phrase(s.autoPhrase)
        ffi_set_association(s.association)
        debugLog("syncConfigToEngine: unique4=\(s.autoCommitUnique4) first5=\(s.autoCommitFirst5) enter=\(s.enterKeyAction) empty=\(s.emptyCodeAction) count=\(s.candidateCountValue) pinyinMixed=\(s.pinyinMixedEnabled) codeHint=\(s.progressiveHint) commonOnly=\(s.commonCharsOnly) traditional=\(s.traditionalOutput)")
    }

    // MARK: - Menu

    override func menu() -> NSMenu! {
        let menu = NSMenu()

        let punctItem = NSMenuItem(title: "中文标点", action: #selector(menuToggleChinesePunct(_:)), keyEquivalent: "")
        punctItem.target = self
        punctItem.state = ffi_get_chinese_punct() ? .on : .off
        menu.addItem(punctItem)

        let widthItem = NSMenuItem(title: "全角", action: #selector(menuToggleFullWidth(_:)), keyEquivalent: "")
        widthItem.target = self
        widthItem.state = ffi_get_full_width() ? .on : .off
        menu.addItem(widthItem)

        let traditionalItem = NSMenuItem(title: "繁体输出", action: #selector(menuToggleTraditional(_:)), keyEquivalent: "")
        traditionalItem.target = self
        traditionalItem.state = ffi_get_traditional() ? .on : .off
        menu.addItem(traditionalItem)

        menu.addItem(NSMenuItem.separator())

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
        alert.informativeText = "版本 \(appVersionText())\n基于 Rust 引擎的五笔输入法"
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
        // 与 commitComposition 同一收尾：有候选提交首选、无候选清空，绝不残留编码字母
        finishComposition(client: sender as? IMKTextInput)
        // 落盘用户词典（自造词/调频持久化）：仅在有实际改动时保存，后台串行写盘不阻塞主线程
        saveUserDictIfNeeded(force: true)
    }

    /// IMK 在组合中途被强制提交时调用（如打字中途鼠标点同 App 内别处）。
    /// 默认实现会把预编辑的编码字母原样插入文档，这里重写以走统一收尾逻辑。
    override func commitComposition(_ sender: Any!) {
        debugLog("commitComposition")
        finishComposition(client: sender as? IMKTextInput)
        saveUserDictIfNeeded(force: false)
    }

    // MARK: - Event Handling

    override func recognizedEvents(_ sender: Any!) -> Int {
        let events: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        return Int(events.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        // 联想态（问引擎）：编码缓冲为空却有联想候选。按键处理完后若联想已结束则收起候选窗；
        // 直通给应用的按键（引擎没看到）先取消联想。非联想态不做任何事。
        let wasAssociating = ffi_is_associating()
        let handled = dispatchKeyEvent(event, client: sender)
        if wasAssociating {
            if !handled && event?.type == .keyDown && ffi_is_associating() {
                let _ = ffi_handle_escape()
            }
            if !ffi_is_associating() && currentBuffer().isEmpty {
                hideCandidates()
            }
        }
        return handled
    }

    private func dispatchKeyEvent(_ event: NSEvent!, client sender: Any!) -> Bool {
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

        // Ctrl+. 切换中/英文标点；Ctrl+Shift+F 切换繁体输出；Shift+空格 切换全角/半角（仅对应修饰键，拦截后不放行给应用）。
        // 须在下方「Ctrl 组合键清码后放行」之前判断。Caps Lock 亮着时 Shift+空格 仍走直通。
        let pureModifiers = modifiers.intersection([.command, .control, .option, .shift])
        if keyCode == 47 && pureModifiers == .control {
            toggleChinesePunct(client: client)
            return true
        }
        if keyCode == 3 && pureModifiers == [.control, .shift] {
            toggleTraditional(client: client)
            return true
        }
        if keyCode == 49 && pureModifiers == .shift && !modifiers.contains(.capsLock) {
            toggleFullWidth(client: client)
            return true
        }

        // 有修饰键的按键不作为编码输入处理。
        // Cmd/Ctrl 属应用快捷键：若组合串在途，先丢弃编码与预编辑再放行，
        // 避免快捷键后继续打字接在旧码后面。
        if modifiers.contains(.command) || modifiers.contains(.control) {
            let bufPtr = ffi_get_buffer()
            let buf = bufPtr.flatMap { String(cString: $0) } ?? ""
            if let ptr = bufPtr { ffi_free_string(ptr) }
            if !buf.isEmpty {
                let _ = ffi_handle_escape()
                client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
                hideCandidates()
            }
            ffi_break_auto_phrase()
            return false
        }
        // Option 可能用于合法字符输入（如 Option+字母），保持透传、不触碰组合串
        if modifiers.contains(.option) {
            ffi_break_auto_phrase()
            return false
        }

        // Caps Lock 亮着：等同英文直通。兜底上屏在途编码后放行，不交给引擎
        if modifiers.contains(.capsLock) {
            commitBufferAsEnglish(client: client)
            ffi_break_auto_phrase()
            return false
        }

        let settings = HangeWubiSettings.shared
        let result: FfiResult

        // Backspace must be checked BEFORE character-based switch,
        // because backspace produces \u{7F} (DEL) which is non-empty
        // and would fall through to the default branch otherwise.
        if keyCode == 51 {
            result = ffi_handle_backspace()
        } else if let handled = handleNavigationKey(keyCode: keyCode, client: client) {
            return handled
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
                    let buf = currentBuffer()
                    if !buf.isEmpty && mode != 1 {
                        // In Chinese mode with buffer, pass as punctuation
                        result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue!))
                    } else {
                        ffi_break_auto_phrase()
                        return false
                    }
                }
            case "'":
                // 单引号：编码非空时选第三候选，否则作为标点
                let mode = ffi_get_mode()
                let buf = currentBuffer()
                if !buf.isEmpty && mode != 1 && settings.quoteSelectThird {
                    result = ffi_handle_quote()
                } else if !buf.isEmpty && mode != 1 {
                    // Feature disabled but buffer non-empty: treat as punctuation
                    result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue!))
                } else {
                    result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue!))
                }
            case "=", "+":
                // 有候选可翻时下一页；否则（含临时英文态）按普通标点交给引擎
                if settings.plusEqualsNextPage && hasCandidates() {
                    let paged = ffi_next_page()
                    result = pageKeyEndedAssociation(paged)
                        ? ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue!)) : paged
                } else {
                    result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue!))
                }
            case "-":
                // 有候选可翻时上一页；否则（含临时英文态）按普通标点交给引擎
                if settings.minusPrevPage && hasCandidates() {
                    let paged = ffi_prev_page()
                    result = pageKeyEndedAssociation(paged)
                        ? ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue!)) : paged
                } else {
                    result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue!))
                }
            case ",", ".":
                if settings.commaPeriodPageFlip && hasCandidates()
                    && flipPage(next: ch == ".", client: client) {
                    return true
                }
                result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue!))
            case "[", "]":
                if hasCandidates() {
                    if settings.bracketPageFlip {
                        if flipPage(next: ch == "]", client: client) { return true }
                    } else if settings.bracketSelectSecondThird && !ffi_is_associating() {
                        // 与 ; ' 同样选当前页第 2/3 候选；不足时吞掉，避免字符漏给应用
                        result = ffi_handle_number(ch == "[" ? 2 : 3)
                        if result.action == FFI_ACTION_UNHANDLED { return true }
                        break
                    }
                }
                result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue!))
            case "0"..."9":
                let num = UInt8(ch.asciiValue! - 48)
                result = ffi_handle_number(num)
            case "a"..."z", "A"..."Z":
                result = ffi_handle_key(Int8(bitPattern: ch.asciiValue!))
                if ffi_take_beep() { NSSound.beep() }
            default:
                if ch.isPunctuation || ",.?!:@#$%^&*-_+=~\\\"'()[]{}<>`|/".contains(ch) {
                    result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue ?? 0))
                } else {
                    // 方向键 / Tab / Home 等直通给应用：对自动造词是打断
                    ffi_break_auto_phrase()
                    return false
                }
            }
        } else {
            ffi_break_auto_phrase()
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
            // 发生了实际提交/选字，引擎可能已更新自造词/词频，标记待落盘
            markUserDictDirty()
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

    // MARK: - Punctuation / Width Toggles

    /// 按设置在光标附近弹出短提示（复用中/英提示窗）
    private func showHint(_ text: String, client: IMKTextInput) {
        guard HangeWubiSettings.shared.showModeIndicator else { return }
        var cursorRect = NSRect.zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &cursorRect)
        ModeIndicatorWindow.shared.show(text: text, near: cursorRect)
    }

    /// 切换中/英文标点（状态在引擎），弹提示
    private func toggleChinesePunct(client: IMKTextInput) {
        let isChinese = ffi_toggle_chinese_punct()
        showHint(isChinese ? "。，" : ".,", client: client)
    }

    /// 切换全角/半角（状态在引擎），弹提示
    private func toggleFullWidth(client: IMKTextInput) {
        let isFull = ffi_toggle_full_width()
        showHint(isFull ? "全" : "半", client: client)
    }

    /// 切换繁体输出（引擎持有状态，同时写入设置以跨重启持久化），弹提示
    private func toggleTraditional(client: IMKTextInput?) {
        let isTraditional = ffi_toggle_traditional()
        HangeWubiSettings.shared.traditionalOutput = isTraditional
        if let client = client { showHint(isTraditional ? "繁" : "简", client: client) }
    }

    @objc private func menuToggleTraditional(_ sender: Any?) {
        toggleTraditional(client: client() as? IMKTextInput)
    }

    @objc private func menuToggleChinesePunct(_ sender: Any?) {
        guard let client = client() as? IMKTextInput else { _ = ffi_toggle_chinese_punct(); return }
        toggleChinesePunct(client: client)
    }

    @objc private func menuToggleFullWidth(_ sender: Any?) {
        guard let client = client() as? IMKTextInput else { _ = ffi_toggle_full_width(); return }
        toggleFullWidth(client: client)
    }

    // MARK: - Modifier Toggle (Shift/Ctrl) via flagsChanged

    private func handleFlagsChanged(event: NSEvent, client: IMKTextInput) -> Bool {
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags

        // 按设置选定切换键：0=Shift（keyCode 56/60），1=Ctrl（keyCode 59/62），其余不切换
        let toggleSetting = HangeWubiSettings.shared.toggleChineseEnglish
        let toggleFlag: NSEvent.ModifierFlags = toggleSetting == 1 ? .control : .shift
        let isToggleKey = toggleSetting == 1 ? (keyCode == 59 || keyCode == 62) : (keyCode == 56 || keyCode == 60)

        // Caps Lock（keyCode 57）：由灭变亮时先把在途编码作为英文上屏；不参与 Shift 单击判定
        if keyCode == 57 {
            shiftPressed = false
            if modifiers.contains(.capsLock) {
                commitBufferAsEnglish(client: client)
            }
            return false
        }

        if !isToggleKey {
            // Some other modifier changed, cancel shift tracking
            shiftPressed = false
            return false
        }

        let shiftIsDown = modifiers.contains(toggleFlag)

        if shiftIsDown {
            // Shift just pressed down - only track if no other modifiers held
            let otherModifiers: NSEvent.ModifierFlags = NSEvent.ModifierFlags([.command, .control, .option, .shift]).subtracting(toggleFlag)
            if modifiers.isDisjoint(with: otherModifiers) {
                shiftPressed = true
                debugLog("Toggle key pressed down (tracking)")
            } else {
                shiftPressed = false
            }
        } else {
            // Shift released
            if shiftPressed && toggleSetting != 2 {
                debugLog("Toggle key released alone - toggling mode")
                // 把已输入的编码作为英文直接上屏，然后切换模式
                commitBufferAsEnglish(client: client)
                ffi_toggle_mode()
                // Show mode indicator if enabled
                showHint(ffi_get_mode() == 0 ? "中" : "英", client: client)
                shiftPressed = false
                return true
            }
            shiftPressed = false
        }

        return false
    }

    // MARK: - Candidate Management

    /// 取当前编码缓冲区并释放 FFI 分配的字符串，返回 Swift 串（空串表示无编码）。
    /// 统一 ffi_get_buffer + free 的往返，避免各调用点重复分配/释放样板。
    private func currentBuffer() -> String {
        let ptr = ffi_get_buffer()
        defer { if let ptr = ptr { ffi_free_string(ptr) } }
        return ptr.flatMap { String(cString: $0) } ?? ""
    }

    /// 把在途编码作为英文原样上屏并清空引擎组合状态/预编辑；无编码时什么都不做。
    private func commitBufferAsEnglish(client: IMKTextInput) {
        let buf = currentBuffer()
        guard !buf.isEmpty else { return }
        // 先上屏英文
        client.insertText(buf, replacementRange: NSRange(location: NSNotFound, length: 0))
        // 再清除引擎状态
        let _ = ffi_handle_escape()
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        hideCandidates()
    }

    /// 当前页是否有候选（问引擎；临时英文态/无编码时为空）。
    private func hasCandidates() -> Bool {
        let list = ffi_get_candidates()
        defer { ffi_free_candidate_list(list) }
        return list.count > 0
    }

    /// 翻页并刷新预编辑/候选窗；无法再翻时引擎返回 Unhandled，不做任何事。
    /// 返回 false 仅当联想态翻到头、引擎已取消联想：该键应按普通键继续处理。
    @discardableResult
    private func flipPage(next: Bool, client: IMKTextInput) -> Bool {
        let result = next ? ffi_next_page() : ffi_prev_page()
        if result.action == FFI_ACTION_UPDATE_CANDIDATES {
            updateMarkedText(client: client)
        }
        return !pageKeyEndedAssociation(result)
    }

    /// 翻页键在联想态翻到头时引擎取消联想并返回 Unhandled（此时缓冲为空且不在联想态）。
    /// 有编码时翻到头缓冲必非空，恒为 false，原有分支不受影响。
    private func pageKeyEndedAssociation(_ result: FfiResult) -> Bool {
        result.action == FFI_ACTION_UNHANDLED && !ffi_is_associating() && currentBuffer().isEmpty
    }

    /// PageUp/PageDown/上下方向键翻页（仅有候选时）；左右方向键在有编码时吞掉。
    /// 返回 nil 表示不是导航键或不适用，继续走原有分发。
    private func handleNavigationKey(keyCode: UInt16, client: IMKTextInput) -> Bool? {
        switch keyCode {
        case 116, 126, 121, 125:  // PageUp, Up, PageDown, Down
            guard hasCandidates() else { return nil }
            return flipPage(next: keyCode == 121 || keyCode == 125, client: client) ? true : nil
        case 123, 124:  // Left, Right
            return currentBuffer().isEmpty ? nil : true
        default:
            return nil
        }
    }

    private func updateMarkedText(client: IMKTextInput) {
        let buffer = currentBuffer()

        if buffer.isEmpty {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            if ffi_is_associating() {
                // 联想态：无预编辑，候选窗显示联想词（无编码行内容、无提示）
                var lineHeightRect = NSRect.zero
                client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineHeightRect)
                CandidateWindow.shared.show(candidates: getCandidateStrings(), code: "", near: lineHeightRect)
            } else {
                hideCandidates()
            }
        } else {
            client.setMarkedText(buffer, selectionRange: NSRange(location: buffer.count, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))

            // Get candidates from FFI
            let candidateStrings = getCandidateStrings()
            let hints = getCandidateHints(count: candidateStrings.count)

            if candidateStrings.isEmpty {
                hideCandidates()
            } else {
                // Get cursor position from client
                var lineHeightRect = NSRect.zero
                client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineHeightRect)
                debugLog("updateMarkedText: cursorRect=\(lineHeightRect) candidates=\(candidateStrings.count)")

                CandidateWindow.shared.show(candidates: candidateStrings, hints: hints, code: buffer, near: lineHeightRect)
            }
        }
    }

    private func hideCandidates() {
        CandidateWindow.shared.hide()
    }

    /// 与 getCandidateStrings 同序的编码提示（剩余编码）；无提示为空串
    private func getCandidateHints(count: Int) -> [String] {
        (0..<count).map { i in
            guard let ptr = ffi_get_candidate_hint(i) else { return "" }
            defer { ffi_free_string(ptr) }
            return String(cString: ptr)
        }
    }

    private func getCandidateStrings() -> [String] {
        let list = ffi_get_candidates()
        var result: [String] = []

        if list.count > 0, let candidates = list.candidates {
            for i in 0..<list.count {
                let candidate = candidates[i]
                if let text = candidate.text {
                    // 只保留汉字本身；编码已在候选窗顶部 code 行单独显示，序号由候选窗绘制
                    result.append(String(cString: text))
                }
            }
        }
        ffi_free_candidate_list(list)

        return result
    }
}
