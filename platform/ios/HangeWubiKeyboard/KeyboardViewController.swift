import UIKit

class KeyboardViewController: UIInputViewController {

    private var keyboardView: KeyboardView!
    private var candidateBar: CandidateBarView!
    private var heightConstraint: NSLayoutConstraint?

    private var engineInitialized = false
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
        saveUserDictIfNeeded(force: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NSLog("[HangeWubi] viewDidAppear called, engineInitialized=\(engineInitialized)")
        // Fallback: on iPad, view dimensions may not be finalized until viewDidAppear
        updateHeight()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateHeight()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.updateHeight()
        })
    }

    // MARK: - Engine Init

    private func initializeEngineAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.initializeEngine()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.engineInitialized {
                    NSLog("[HangeWubi] Engine ready, keyboard fully functional")
                }
            }
        }
    }

    private func initializeEngine() {
        guard let wubiPath = Bundle(for: type(of: self)).path(forResource: "wubi86", ofType: "txt") else {
            NSLog("[HangeWubi] wubi86.txt not found in extension bundle")
            return
        }
        let pinyinPath = Bundle(for: type(of: self)).path(forResource: "pinyin", ofType: "txt")

        NSLog("[HangeWubi] Starting ffi_init_with_pinyin...")
        let start = CFAbsoluteTimeGetCurrent()
        let count = ffi_init_with_pinyin(wubiPath, pinyinPath)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        NSLog("[HangeWubi] ffi_init completed in %.3f seconds", elapsed)
        if count < 0 {
            NSLog("[HangeWubi] Failed to initialize engine")
        } else {
            let hasPinyin = pinyinPath != nil
            NSLog("[HangeWubi] Engine initialized, loaded \(count) wubi entries, pinyin=\(hasPinyin)")
            engineInitialized = true
            // 加载用户词典（自造词/调频持久化）。引擎为进程内全局单例，只在首个实例加载一次，
            // 避免后续实例用磁盘旧内容覆盖内存中尚未落盘的自学习数据。
            loadUserDictOnce()
            applySharedSettings(hasPinyin: hasPinyin)
        }
    }

    /// 从 App Group 读取共享设置并应用到引擎
    private func applySharedSettings(hasPinyin: Bool) {
        let defaults = UserDefaults(suiteName: "group.com.hangewubi.app")
        let pinyinEnabled = hasPinyin && (defaults?.bool(forKey: "pinyin_mixed_enabled") ?? false)
        let autoCommit4 = defaults?.object(forKey: "auto_commit_unique_4") as? Bool ?? true
        let autoCommit5 = defaults?.object(forKey: "auto_commit_first_5") as? Bool ?? true
        ffi_set_config(autoCommit4, autoCommit5, 0, 0, 5, pinyinEnabled)
        NSLog("[HangeWubi] Settings applied: pinyin=\(pinyinEnabled) auto4=\(autoCommit4) auto5=\(autoCommit5)")
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
            candidateBar.heightAnchor.constraint(equalToConstant: 40),

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

    private var isLandscape: Bool {
        let size = UIScreen.main.bounds.size
        return size.width > size.height
    }

    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var totalHeight: CGFloat {
        let candidateHeight: CGFloat = 40
        let keyboardHeight: CGFloat
        if isIPad {
            keyboardHeight = isLandscape ? 220 : 280
        } else {
            keyboardHeight = isLandscape ? 162 : 216
        }
        let height = candidateHeight + keyboardHeight
        // Guard against zero/invalid height during early lifecycle on iPad
        return max(height, 200)
    }

    private func updateHeight() {
        heightConstraint?.constant = totalHeight
    }

    // MARK: - Engine Interaction

    /// 处理引擎返回结果。`fallbackInsert` 为引擎返回 UNHANDLED 时的兜底字符：
    /// 数字/标点等在空 buffer 或未命中映射时引擎会返回 Unhandled，若不兜底会被静默吞掉。
    /// 返回值：当路径刷新了候选（COMMIT/UPDATE）时携带最新 buffer 与候选数，供上层复用，
    /// 避免重复的 FFI 往返（见 autoCommitIfBufferFull）。
    @discardableResult
    private func processResult(_ result: FfiResult, fallbackInsert: String? = nil) -> (buffer: String, count: Int)? {
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
            return refreshCandidates()

        case FFI_ACTION_UPDATE_CANDIDATES:
            if let text = result.text {
                ffi_free_string(text)
            }
            return refreshCandidates()

        case FFI_ACTION_RESET:
            if let text = result.text {
                ffi_free_string(text)
            }
            textDocumentProxy.unmarkText()
            candidateBar.clear()
            return nil

        case FFI_ACTION_UNHANDLED:
            if let text = result.text {
                ffi_free_string(text)
            }
            if let fallback = fallbackInsert {
                textDocumentProxy.insertText(fallback)
            }
            return nil

        default:
            if let text = result.text {
                ffi_free_string(text)
            }
            return nil
        }
    }

    @discardableResult
    private func refreshCandidates() -> (buffer: String, count: Int) {
        // Get current buffer
        let bufferPtr = ffi_get_buffer()
        let buffer = bufferPtr.flatMap { String(cString: $0) } ?? ""
        if let ptr = bufferPtr { ffi_free_string(ptr) }

        // Get candidates
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

        // Show composing text inline at the cursor via marked text
        if !buffer.isEmpty {
            textDocumentProxy.setMarkedText(buffer.uppercased(), selectedRange: NSRange(location: buffer.count, length: 0))
        } else {
            textDocumentProxy.unmarkText()
        }

        // Preedit is now shown inline; keep the label empty
        candidateBar.updatePreedit("")
        candidateBar.updateCandidates(candidates)
        candidateBar.isHidden = candidates.isEmpty
        return (buffer: buffer, count: candidates.count)
    }

    /// 满 4 码自动上屏：模仿 iOS 系统五笔行为。
    /// 如果引擎已自动 commit（unique 4 码），buffer 已为空，无操作；否则提交首选候选。
    /// buffer/count 复用字母键路径已从引擎取回的值，避免重复 FFI 往返（I-L1）。
    private func autoCommitIfBufferFull(buffer: String?, count: Int?) {
        guard let buffer = buffer, let count = count else { return }
        guard buffer.count >= 4, count > 0 else { return }
        let result = ffi_handle_number(1)
        processResult(result)
    }

    private func getBuffer() -> String {
        let ptr = ffi_get_buffer()
        let s = ptr.flatMap { String(cString: $0) } ?? ""
        if let p = ptr { ffi_free_string(p) }
        return s
    }

    /// 取当前候选文本列表（供强制收尾提交首选候选用）。
    private func currentCandidateStrings() -> [String] {
        let list = ffi_get_candidates()
        var result: [String] = []
        if list.count > 0, let items = list.candidates {
            for i in 0..<list.count {
                result.append(items[i].text.flatMap { String(cString: $0) } ?? "")
            }
        }
        ffi_free_candidate_list(list)
        return result
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

        if let first = currentCandidateStrings().first {
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
                let info = processResult(result)
                // 五笔最多 4 码：满 4 码且仍有候选时，自动选择第一候选上屏（复用 info 避免重复 FFI）
                autoCommitIfBufferFull(buffer: info?.buffer, count: info?.count)
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
        guard engineInitialized else { return }
        // ffi_handle_number uses 1-based indexing for candidate selection
        let num = UInt8(index + 1)
        let result = ffi_handle_number(num)
        processResult(result)
    }
}
