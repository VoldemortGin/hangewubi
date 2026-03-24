import InputMethodKit
import Cocoa

// 函戈五笔 macOS 输入法入口

let bundleId = Bundle.main.bundleIdentifier ?? "com.hangewubi.inputmethod"
let connectionName = "HangeWubi_Connection"

guard let server = IMKServer(name: connectionName, bundleIdentifier: bundleId) else {
    NSLog("[函戈五笔] 无法创建 IMKServer")
    exit(1)
}

NSLog("[函戈五笔] 输入法服务已启动: \(connectionName)")

// 运行主事件循环
NSApplication.shared.run()
