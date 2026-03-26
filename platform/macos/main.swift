import InputMethodKit
import Cocoa

// 晗戈五笔 macOS 输入法入口

let bundleId = Bundle.main.bundleIdentifier ?? "com.hangewubi.inputmethod.HangeWubi"
let connectionName = "com.hangewubi.inputmethod.HangeWubi_Connection"

guard let server = IMKServer(name: connectionName, bundleIdentifier: bundleId) else {
    NSLog("[晗戈五笔] 无法创建 IMKServer")
    exit(1)
}

NSLog("[晗戈五笔] 输入法服务已启动: \(connectionName)")

// 创建候选词窗口（全局共享）
let sharedCandidates = IMKCandidates(server: server, panelType: kIMKSingleColumnScrollingCandidatePanel)
NSLog("[晗戈五笔] 候选词窗口已创建")

// 验证 InputController 类是否可被 ObjC runtime 找到
if let cls = NSClassFromString("InputController") {
    NSLog("[晗戈五笔] 找到 InputController 类: \(cls)")
} else {
    NSLog("[晗戈五笔] ⚠️ 无法找到 InputController 类！尝试模块限定名...")
    if let cls = NSClassFromString("HangeWubi.InputController") {
        NSLog("[晗戈五笔] 找到 HangeWubi.InputController: \(cls)")
    } else {
        NSLog("[晗戈五笔] ⚠️ 也无法找到 HangeWubi.InputController")
    }
}

// 运行主事件循环
NSApplication.shared.run()
