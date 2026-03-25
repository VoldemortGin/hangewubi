import UIKit

class KeyboardViewController: UIInputViewController {

    private var keyboardView: KeyboardView!
    private var candidateBar: CandidateBarView!
    private var heightConstraint: NSLayoutConstraint?

    private var engineInitialized = false
    private var isChinese = true  // true = Chinese mode, false = English pass-through

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        initializeEngine()
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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

    private func initializeEngine() {
        guard let bundle = Bundle(for: type(of: self)).path(forResource: "wubi86", ofType: "txt") else {
            NSLog("[HangeWubi] wubi86.txt not found in extension bundle")
            return
        }
        let count = ffi_init(bundle)
        if count < 0 {
            NSLog("[HangeWubi] Failed to initialize engine")
        } else {
            NSLog("[HangeWubi] Engine initialized, loaded \(count) entries")
            engineInitialized = true
            // Apply default config
            ffi_set_config(true, true, 0, 0, 5)
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

    private var totalHeight: CGFloat {
        let candidateHeight: CGFloat = 40
        let keyboardHeight: CGFloat = isLandscape ? 162 : 216
        return candidateHeight + keyboardHeight
    }

    private func updateHeight() {
        heightConstraint?.constant = totalHeight
    }

    // MARK: - Engine Interaction

    private func processResult(_ result: FfiResult) {
        switch result.action {
        case FFI_ACTION_COMMIT:
            if let text = result.text {
                let str = String(cString: text)
                textDocumentProxy.insertText(str)
                ffi_free_string(text)
            }
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
            candidateBar.clear()

        case FFI_ACTION_UNHANDLED:
            if let text = result.text {
                ffi_free_string(text)
            }

        default:
            if let text = result.text {
                ffi_free_string(text)
            }
        }
    }

    private func refreshCandidates() {
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

        candidateBar.updatePreedit(buffer)
        candidateBar.updateCandidates(candidates)
        candidateBar.isHidden = buffer.isEmpty && candidates.isEmpty
    }

    private func getBuffer() -> String {
        let ptr = ffi_get_buffer()
        let s = ptr.flatMap { String(cString: $0) } ?? ""
        if let p = ptr { ffi_free_string(p) }
        return s
    }
}

// MARK: - KeyboardViewDelegate

extension KeyboardViewController: KeyboardViewDelegate {

    func keyboardView(_ view: KeyboardView, didTapKey key: String) {
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
                processResult(result)
            } else if ch.isNumber {
                let num = UInt8(ch.asciiValue! - Character("0").asciiValue!)
                let result = ffi_handle_number(num)
                processResult(result)
            } else if ch.isPunctuation || ",.?!:;@#$%^&*-_+=~\\\"'()[]{}<>/".contains(ch) {
                let result = ffi_handle_punctuation(Int8(bitPattern: ch.asciiValue ?? 0))
                processResult(result)
            } else {
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
        guard engineInitialized else { return }
        // ffi_handle_number uses 1-based indexing for candidate selection
        let num = UInt8(index + 1)
        let result = ffi_handle_number(num)
        processResult(result)
    }
}
