import UIKit

class KeyboardViewController: UIInputViewController {

    private var keyboardView: KeyboardView!
    private var candidateBar: CandidateBarView!
    private var heightConstraint: NSLayoutConstraint?

    private var engineInitialized = false
    // 引擎异步初始化期间的按键按序缓存，就绪（或失败）后按原顺序重放
    private enum PendingInput {
        case key(String), backspace, space, ret, shift
    }
    private var engineLoading = true
    private var pendingInputs: [PendingInput] = []

    // 候选栏横向滚动追加加载：引擎始终停在第 0 页（空格/标点/顶字均取第 0 页首选），
    // 追加时临时翻页取数据后翻回；点选第 n 个候选时翻到其所在页再按页内序号选择。
    private var candidatePageSize = 0
    private var loadedCandidatePages = 0
    private var candidatesExhausted = true
    private var isChinese = true  // true = Chinese mode, false = English pass-through

    // 组合收尾：区分「键盘自身编辑引发的 textWillChange」与「输入目标真正切换」
    private var isSelfEditing = false
    private var selfEditGeneration = 0

    // 用户词典落盘（引擎/词典为进程内全局单例，用类型级共享状态串行落盘，
    // 参照 macOS InputController 的持久化策略）
    private static var userDictLoaded = false
    private static var userDictDirty = false
    private static var lastSaveTime = Date.distantPast
    private static let saveThrottleInterval: TimeInterval = 10
    private static let saveQueue = DispatchQueue(label: "com.hangewubi.keyboard.userdict.save")

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("[HangeWubi] viewDidLoad called, device idiom=\(UIDevice.current.userInterfaceIdiom.rawValue)")
        setupUI()
        initializeEngineAsync()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NSLog("[HangeWubi] viewWillAppear called")
        keyboardView?.showGlobeKey = needsInputModeSwitchKey
        updateHeight()
        updateReturnKey()
        // 每次键盘显示时重新加载设置（用户可能在主 App 中修改了设置）
        applySharedSettingsFromDefaults()
        if engineInitialized {
            applySharedSettings(hasPinyin: true)
        }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        updateReturnKey()
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        // 输入目标即将切换（点了另一个输入框/移动光标等）：收尾在途组合，
        // 避免残码被系统定稿成字面文本、引擎 buffer 串场到下一个目标。
        // 键盘自身的 insertText/setMarkedText 也会引发此回调，用 isSelfEditing 屏蔽，
        // 以免误伤正常打字路径。
        if isSelfEditing { return }
        finishComposition()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 键盘即将隐藏（切键盘/退到后台/收起）：收尾在途组合并强制落盘用户词典。
        finishComposition()
        pendingInputs.removeAll()
        saveUserDictIfNeeded(force: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NSLog("[HangeWubi] viewDidAppear called, engineInitialized=\(engineInitialized)")
    }

    // 高度随键盘容器实际宽度更新：旋转 / 折叠屏展开 / 分屏等宽度变化都会触发布局
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateHeight()
    }

    // MARK: - Engine Init

    private func initializeEngineAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = self?.initializeEngine() ?? false
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 就绪标志与重放在主线程同一块内完成，保证缓存按键先于后续新按键处理
                self.engineInitialized = ok
                self.engineLoading = false
                if ok {
                    NSLog("[HangeWubi] Engine ready, keyboard fully functional")
                }
                self.replayPendingInputs()
            }
        }
    }

    private func initializeEngine() -> Bool {
        guard let wubiPath = Bundle(for: type(of: self)).path(forResource: "wubi86", ofType: "txt") else {
            NSLog("[HangeWubi] wubi86.txt not found in extension bundle")
            return false
        }
        let pinyinPath = Bundle(for: type(of: self)).path(forResource: "pinyin", ofType: "txt")

        NSLog("[HangeWubi] Starting ffi_init_with_pinyin...")
        let start = CFAbsoluteTimeGetCurrent()
        let count = ffi_init_with_pinyin(wubiPath, pinyinPath)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        NSLog("[HangeWubi] ffi_init completed in %.3f seconds", elapsed)
        if count < 0 {
            NSLog("[HangeWubi] Failed to initialize engine")
            return false
        } else {
            let hasPinyin = pinyinPath != nil
            NSLog("[HangeWubi] Engine initialized, loaded \(count) wubi entries, pinyin=\(hasPinyin)")
            // 加载用户词典（自造词/调频持久化）。引擎为进程内全局单例，只在首个实例加载一次，
            // 避免后续实例用磁盘旧内容覆盖内存中尚未落盘的自学习数据。
            loadUserDictOnce()
            applySharedSettings(hasPinyin: hasPinyin)
            return true
        }
    }

    /// 重放引擎就绪前缓存的按键；初始化失败时各入口走未初始化兜底（原样插入）。
    private func replayPendingInputs() {
        let inputs = pendingInputs
        pendingInputs.removeAll()
        for input in inputs {
            switch input {
            case .key(let key): keyboardView(self.keyboardView, didTapKey: key)
            case .backspace: keyboardViewDidTapBackspace(self.keyboardView)
            case .space: keyboardViewDidTapSpace(self.keyboardView)
            case .ret: keyboardViewDidTapReturn(self.keyboardView)
            case .shift: keyboardViewDidTapShift(self.keyboardView)
            }
        }
    }

    /// 引擎仍在初始化时缓存按键并返回 true，调用方直接返回。
    private func enqueueIfEngineLoading(_ input: PendingInput) -> Bool {
        guard engineLoading else { return false }
        pendingInputs.append(input)
        return true
    }

    /// 从 App Group 读取共享设置并应用到引擎
    private func applySharedSettings(hasPinyin: Bool) {
        let defaults = UserDefaults(suiteName: "group.com.hangewubi.app")
        let pinyinEnabled = hasPinyin && (defaults?.bool(forKey: "pinyin_mixed_enabled") ?? false)
        let autoCommit4 = defaults?.object(forKey: "auto_commit_unique_4") as? Bool ?? true
        let autoCommit5 = defaults?.object(forKey: "auto_commit_first_5") as? Bool ?? true
        let candidateCount = UInt8(clamping: defaults?.object(forKey: "candidate_count") as? Int ?? 5)
        ffi_set_config(autoCommit4, autoCommit5, 0, 0, candidateCount, pinyinEnabled)
        NSLog("[HangeWubi] Settings applied: pinyin=\(pinyinEnabled) auto4=\(autoCommit4) auto5=\(autoCommit5) candidates=\(candidateCount)")
    }

    /// 从 App Group 读取只作用于键盘视图的设置（震动等）
    private func applySharedSettingsFromDefaults() {
        let defaults = UserDefaults(suiteName: "group.com.hangewubi.app")
        let haptic = defaults?.bool(forKey: "haptic_enabled") ?? false
        keyboardView?.hapticEnabled = haptic
    }

    /// 根据宿主 App 的 returnKeyType 动态设置换行键文案与颜色
    private func updateReturnKey() {
        guard let keyboardView = keyboardView else { return }
        let type = textDocumentProxy.returnKeyType ?? .default
        let (title, isAction) = Self.returnKeyAttributes(for: type)
        keyboardView.returnTitle = title
        keyboardView.returnStyle = isAction ? .action : .normal
    }

    private static func returnKeyAttributes(for type: UIReturnKeyType) -> (String, Bool) {
        switch type {
        case .go:       return ("前往", true)
        case .google:   return ("Google", true)
        case .join:     return ("加入", true)
        case .next:     return ("下一项", false)
        case .route:    return ("路线", true)
        case .search:   return ("搜索", true)
        case .send:     return ("发送", true)
        case .yahoo:    return ("Yahoo", true)
        case .done:     return ("完成", true)
        case .emergencyCall: return ("紧急呼叫", true)
        case .continue: return ("继续", true)
        default:        return ("换行", false)
        }
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let inputView = self.inputView else { return }
        inputView.allowsSelfSizing = true

        // Candidate bar
        candidateBar = CandidateBarView()
        candidateBar.delegate = self
        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        candidateBar.isHidden = true
        inputView.addSubview(candidateBar)

        // Keyboard view
        keyboardView = KeyboardView()
        keyboardView.delegate = self
        keyboardView.showGlobeKey = needsInputModeSwitchKey
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        inputView.addSubview(keyboardView)

        NSLayoutConstraint.activate([
            candidateBar.topAnchor.constraint(equalTo: inputView.topAnchor),
            candidateBar.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            candidateBar.heightAnchor.constraint(equalToConstant: KeyboardMetrics.candidateBarHeight),

            keyboardView.topAnchor.constraint(equalTo: candidateBar.bottomAnchor),
            keyboardView.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: inputView.bottomAnchor),
        ])

        // Total height constraint
        heightConstraint = inputView.heightAnchor.constraint(equalToConstant: totalHeight)
        heightConstraint?.priority = .required - 1
        heightConstraint?.isActive = true
    }

    private var totalHeight: CGFloat {
        let keyboardHeight = KeyboardMetrics.keyboardHeight(
            width: view.bounds.width, verticalSizeClass: traitCollection.verticalSizeClass)
        let height = KeyboardMetrics.candidateBarHeight + keyboardHeight
        // Guard against zero/invalid height during early lifecycle on iPad
        return max(height, 200)
    }

    private func updateHeight() {
        let height = totalHeight
        if heightConstraint?.constant != height {
            heightConstraint?.constant = height
        }
    }

    // MARK: - Engine Interaction

    /// 处理引擎返回结果。`fallbackInsert` 为引擎返回 UNHANDLED 时的兜底字符：
    /// 数字/标点等在空 buffer 或未命中映射时引擎会返回 Unhandled，若不兜底会被静默吞掉。
    private func processResult(_ result: FfiResult, fallbackInsert: String? = nil) {
        switch result.action {
        case FFI_ACTION_COMMIT:
            if let text = result.text {
                let str = String(cString: text)
                textDocumentProxy.insertText(str)
                ffi_free_string(text)
            }
            // 发生了实际提交/选字，引擎可能已更新自造词/词频，标记待落盘
            markUserDictDirty()
            saveUserDictIfNeeded(force: false)
            refreshCandidates()

        case FFI_ACTION_UPDATE_CANDIDATES:
            if let text = result.text {
                ffi_free_string(text)
            }
            refreshCandidates()

        case FFI_ACTION_RESET:
            if let text = result.text {
                ffi_free_string(text)
            }
            textDocumentProxy.unmarkText()
            candidateBar.clear()

        case FFI_ACTION_UNHANDLED:
            if let text = result.text {
                ffi_free_string(text)
            }
            if let fallback = fallbackInsert {
                textDocumentProxy.insertText(fallback)
            }

        default:
            if let text = result.text {
                ffi_free_string(text)
            }
        }
    }

    private func refreshCandidates() {
        let buffer = getBuffer()
        let candidates = currentPageCandidates()
        candidatePageSize = candidates.count
        loadedCandidatePages = 1
        candidatesExhausted = candidates.isEmpty

        // Show composing text inline at the cursor via marked text
        if !buffer.isEmpty {
            textDocumentProxy.setMarkedText(buffer.uppercased(), selectedRange: NSRange(location: buffer.count, length: 0))
        } else {
            textDocumentProxy.unmarkText()
        }

        // Preedit is now shown inline; keep the label empty
        candidateBar.updatePreedit("")
        candidateBar.updateCandidates(candidates, input: buffer)
        candidateBar.isHidden = candidates.isEmpty
    }

    /// 取引擎当前页候选（text + code）。
    private func currentPageCandidates() -> [(text: String, code: String)] {
        let list = ffi_get_candidates()
        var candidates: [(text: String, code: String)] = []
        if list.count > 0, let items = list.candidates {
            for i in 0..<list.count {
                let c = items[i]
                let text = c.text.flatMap { String(cString: $0) } ?? ""
                let code = c.code.flatMap { String(cString: $0) } ?? ""
                candidates.append((text: text, code: code))
            }
        }
        ffi_free_candidate_list(list)
        return candidates
    }

    /// 连续翻 `pages` 页，返回实际翻过的页数（遇到末页即停）。
    private func turnPages(forward: Bool, _ pages: Int) -> Int {
        var turned = 0
        while turned < pages {
            let result = forward ? ffi_next_page() : ffi_prev_page()
            if let text = result.text { ffi_free_string(text) }
            guard result.action == FFI_ACTION_UPDATE_CANDIDATES else { break }
            turned += 1
        }
        return turned
    }

    /// 追加加载下一页候选：翻到下一页取数据后翻回第 0 页，保持引擎页状态不变。
    private func loadMoreCandidates() {
        guard engineInitialized, !candidatesExhausted else { return }
        let turned = turnPages(forward: true, loadedCandidatePages)
        let more = turned == loadedCandidatePages ? currentPageCandidates() : []
        _ = turnPages(forward: false, turned)
        guard !more.isEmpty else {
            candidatesExhausted = true
            return
        }
        loadedCandidatePages += 1
        candidateBar.appendCandidates(more)
    }

    private func getBuffer() -> String {
        let ptr = ffi_get_buffer()
        let s = ptr.flatMap { String(cString: $0) } ?? ""
        if let p = ptr { ffi_free_string(p) }
        return s
    }

    // MARK: - Composition Finalize

    /// 组合被强制结束时的统一收尾（viewWillDisappear / textWillChange 共用）。
    /// 有候选 → 提交首选候选；无候选 → 清空；随后重置引擎，绝不让编码字母原文（如 WGKQ）
    /// 被系统定稿进文档。
    ///
    /// marked text 提交顺序：iOS 上 `unmarkText()` 会把「当前的 marked text」定稿为真实文本，
    /// 而此刻 marked text 是原始编码（WGKQ），直接 unmark 就会把字母漏进文档。
    /// 正确顺序是先 `setMarkedText(候选)` 用候选替换 marked 区域，再 `unmarkText()` 定稿，
    /// 这样落进文档的是候选词而非编码。无候选时 `setMarkedText("")` + `unmarkText()` 清干净。
    private func finishComposition() {
        guard engineInitialized else { return }
        let buffer = getBuffer()
        // 无在途组合：直接返回，正常打字/空闲路径无副作用。
        guard !buffer.isEmpty else { return }

        if let first = currentPageCandidates().first?.text {
            textDocumentProxy.setMarkedText(first, selectedRange: NSRange(location: first.count, length: 0))
            textDocumentProxy.unmarkText()
            markUserDictDirty()
        } else {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            textDocumentProxy.unmarkText()
        }
        _ = ffi_handle_escape()
        candidateBar.clear()
    }

    /// 标记接下来对 textDocumentProxy 的改动来自键盘自身，使随之而来的 textWillChange
    /// 不被误判为「输入目标切换」。proxy 改动跨进程异步回传，故标志位延到下一 runloop
    /// 复位，以覆盖同周期内到达的回调；用 generation 保证仅最后一次编辑负责复位。
    private func markSelfEditing() {
        isSelfEditing = true
        selfEditGeneration += 1
        let gen = selfEditGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.selfEditGeneration == gen else { return }
            self.isSelfEditing = false
        }
    }

    // MARK: - User Dictionary Persistence

    /// 用户词典持久化路径：App Group 容器 /晗戈五笔/user_dict.json（键盘扩展沙箱内可写、
    /// 跨进程被杀后仍在，且与主 App 共享）。App Group 未配置时退化到扩展自身容器。
    private var userDictPath: String {
        let fm = FileManager.default
        let baseDir = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.hangewubi.app")
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = baseDir.appendingPathComponent("晗戈五笔", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("user_dict.json").path
    }

    private func loadUserDictOnce() {
        guard !KeyboardViewController.userDictLoaded else { return }
        KeyboardViewController.userDictLoaded = true
        let path = userDictPath
        let ok = path.withCString { ffi_load_user_dict($0) }
        NSLog("[HangeWubi] load user dict: \(path) -> \(ok)")
    }

    private func markUserDictDirty() {
        KeyboardViewController.userDictDirty = true
    }

    /// 按需落盘：仅在有实际改动时保存，主线程节流，写盘放后台串行队列。
    /// force=true 跳过节流（失焦/隐藏兜底）。ffi_save_user_dict 内部有全局锁，后台调用安全。
    private func saveUserDictIfNeeded(force: Bool) {
        guard KeyboardViewController.userDictDirty else { return }
        let now = Date()
        if !force && now.timeIntervalSince(KeyboardViewController.lastSaveTime) < KeyboardViewController.saveThrottleInterval {
            return
        }
        KeyboardViewController.userDictDirty = false
        KeyboardViewController.lastSaveTime = now
        let path = userDictPath
        KeyboardViewController.saveQueue.async {
            let ok = path.withCString { ffi_save_user_dict($0) }
            NSLog("[HangeWubi] save user dict: \(path) -> \(ok)")
        }
    }
}

// MARK: - KeyboardViewDelegate

extension KeyboardViewController: KeyboardViewDelegate {

    func keyboardView(_ view: KeyboardView, didTapKey key: String) {
        if enqueueIfEngineLoading(.key(key)) { return }
        markSelfEditing()
        guard engineInitialized else {
            textDocumentProxy.insertText(key)
            return
        }

        let mode = ffi_get_mode()
        // mode: 0=Chinese, 1=English, 2=Temp English
        if mode == 1 {
            // English mode: pass through directly
            textDocumentProxy.insertText(key)
            return
        }

        if key.count == 1, let ch = key.first {
            if ch.isLetter {
                let lower = ch.lowercased()
                let result = ffi_handle_key(Int8(bitPattern: Character(lower).asciiValue!))
                // 上屏时机（四码唯一 / 第五码顶字）完全由引擎决定，宿主只消费结果
                processResult(result)
            } else if ch.isNumber {
                // 数字身兼两职：空 buffer 时是字面数字（走系统），非空时是候选选择。
                // 空 buffer 直接 insertText 才能打出 0-9（引擎对空 buffer / num==0 会返回 Unhandled）。
                if getBuffer().isEmpty {
                    textDocumentProxy.insertText(key)
                } else {
                    let num = UInt8(ch.asciiValue! - Character("0").asciiValue!)
                    let result = ffi_handle_number(num)
                    // 非法候选序号（如 0）引擎返回 Unhandled 时兜底为字面字符
                    processResult(result, fallbackInsert: key)
                }
            } else if ch.isPunctuation || ",.?!:;@#$%^&*-_+=~\\\"'()[]{}<>/".contains(ch) {
                // 标点始终交引擎（做中文全角转换 / 提交在途码），仅当引擎未命中映射
                // （如 `/`）返回 Unhandled 时兜底为字面字符，避免被静默吞掉。
                let result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue ?? 0))
                processResult(result, fallbackInsert: key)
            } else {
                // 其它未识别单字符：先提交在途码再插入，避免残留组合串
                let buffer = getBuffer()
                if !buffer.isEmpty {
                    let result = ffi_handle_enter()
                    processResult(result)
                }
                textDocumentProxy.insertText(key)
            }
        } else {
            // Multi-byte characters (like 。)
            // If we have buffer content, commit first
            let buffer = getBuffer()
            if !buffer.isEmpty {
                let result = ffi_handle_enter()
                processResult(result)
            }
            textDocumentProxy.insertText(key)
        }
    }

    func keyboardViewDidTapBackspace(_ view: KeyboardView) {
        if enqueueIfEngineLoading(.backspace) { return }
        markSelfEditing()
        guard engineInitialized else {
            textDocumentProxy.deleteBackward()
            return
        }

        let buffer = getBuffer()
        if buffer.isEmpty {
            textDocumentProxy.deleteBackward()
        } else {
            let result = ffi_handle_backspace()
            processResult(result)
        }
    }

    func keyboardViewDidTapSpace(_ view: KeyboardView) {
        if enqueueIfEngineLoading(.space) { return }
        markSelfEditing()
        guard engineInitialized else {
            textDocumentProxy.insertText(" ")
            return
        }

        let mode = ffi_get_mode()
        let buffer = getBuffer()
        if mode == 1 || buffer.isEmpty {
            textDocumentProxy.insertText(" ")
        } else {
            let result = ffi_handle_space()
            processResult(result)
        }
    }

    func keyboardViewDidTapReturn(_ view: KeyboardView) {
        if enqueueIfEngineLoading(.ret) { return }
        markSelfEditing()
        guard engineInitialized else {
            textDocumentProxy.insertText("\n")
            return
        }

        let buffer = getBuffer()
        if buffer.isEmpty {
            textDocumentProxy.insertText("\n")
        } else {
            let result = ffi_handle_enter()
            processResult(result)
        }
    }

    func keyboardViewDidTapGlobe(_ view: KeyboardView) {
        advanceToNextInputMode()
    }

    func keyboardViewDidTapShift(_ view: KeyboardView) {
        if enqueueIfEngineLoading(.shift) { return }
        markSelfEditing()
        // Toggle Chinese/English mode
        if engineInitialized {
            // If there's buffer content, commit it first as raw text
            let buffer = getBuffer()
            if !buffer.isEmpty {
                let result = ffi_handle_enter()
                processResult(result)
            }
            ffi_toggle_mode()
            let mode = ffi_get_mode()
            isChinese = (mode == 0)
            keyboardView.isEnglishMode = !isChinese
            textDocumentProxy.unmarkText()
            candidateBar.clear()
        }
    }

    func keyboardViewDidTapModeSwitch(_ view: KeyboardView) {
        // Handled inside KeyboardView (letter/number toggle)
    }
}

// MARK: - CandidateBarViewDelegate

extension KeyboardViewController: CandidateBarViewDelegate {

    func candidateBarView(_ view: CandidateBarView, didSelectCandidateAt index: Int) {
        markSelfEditing()
        guard engineInitialized, candidatePageSize > 0 else { return }
        // 引擎按「当前页 + 页内 1-based 序号」选词：翻到目标页再选，未上屏则翻回第 0 页
        let page = index / candidatePageSize
        let turned = turnPages(forward: true, page)
        guard turned == page else {
            _ = turnPages(forward: false, turned)
            return
        }
        let result = ffi_handle_number(UInt8(index % candidatePageSize + 1))
        if result.action != FFI_ACTION_COMMIT {
            _ = turnPages(forward: false, turned)
        }
        processResult(result)
    }

    func candidateBarViewDidScrollNearEnd(_ view: CandidateBarView) {
        loadMoreCandidates()
    }
}
