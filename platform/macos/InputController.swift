import InputMethodKit

/// 函戈五笔 macOS 输入法控制器
/// 通过 C FFI 调用 Rust 引擎
class InputController: IMKInputController {

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)

        // 初始化 Rust 引擎
        let bundlePath = Bundle.main.resourcePath ?? ""
        let dictPath = "\(bundlePath)/data/wubi86.txt"
        let count = ffi_init(dictPath)
        if count < 0 {
            NSLog("[函戈五笔] 码表加载失败: \(dictPath)")
        } else {
            NSLog("[函戈五笔] 已加载 \(count) 条词条")
        }
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, let client = sender as? IMKTextInput else {
            return false
        }

        let keyCode = event.keyCode
        let chars = event.characters ?? ""
        let modifiers = event.modifierFlags

        // Shift 切换中英文
        if modifiers.contains(.shift) && chars.isEmpty {
            ffi_toggle_mode()
            return true
        }

        // 有 Cmd/Ctrl/Option 修饰键的不处理
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
            return false
        }

        let result: FfiResult

        if let ch = chars.first {
            switch ch {
            case " ":
                result = ffi_handle_space()
            case "\r", "\n":
                result = ffi_handle_enter()
            case "\u{1B}":  // Escape
                result = ffi_handle_escape()
            case ";":
                result = ffi_handle_semicolon()
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
        } else if keyCode == 51 {  // Backspace
            result = ffi_handle_backspace()
        } else {
            return false
        }

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
            return true

        case FFI_ACTION_UNHANDLED:
            return false

        default:
            return false
        }
    }

    private func updateMarkedText(client: IMKTextInput) {
        let bufferPtr = ffi_get_buffer()
        let buffer = bufferPtr.flatMap { String(cString: $0) } ?? ""
        if let ptr = bufferPtr { ffi_free_string(ptr) }

        if buffer.isEmpty {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        } else {
            client.setMarkedText(buffer, selectionRange: NSRange(location: buffer.count, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        }
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
