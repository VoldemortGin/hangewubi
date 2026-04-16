import UIKit

/// 通过 App Group 共享的设置键名
enum SettingsKey {
    static let suiteName = "group.com.hangewubi.app"
    static let pinyinMixedEnabled = "pinyin_mixed_enabled"
    static let autoCommitUnique4 = "auto_commit_unique_4"
    static let autoCommitFirst5 = "auto_commit_first_5"
    static let candidateCount = "candidate_count"
    static let hapticEnabled = "haptic_enabled"
}

class SettingsViewController: UITableViewController {

    private let sections = ["输入设置", "五笔设置", "键盘"]
    private let inputSettings = ["五笔拼音混输"]
    private let wubiSettings = ["四码唯一自动上屏", "五码首选自动上屏"]
    private let keyboardSettings = ["按键震动反馈"]

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: SettingsKey.suiteName)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    // MARK: - DataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            return "开启后可在输入五笔编码的同时匹配拼音候选词，五笔结果始终优先显示。"
        case 2:
            return "开启后每次按键都会有轻微震动反馈。如果无震动效果，可在系统「设置 → 通用 → 键盘 → 晗戈五笔」中开启「允许完全访问」。"
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return inputSettings.count
        case 1: return wubiSettings.count
        case 2: return keyboardSettings.count
        default: return 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.selectionStyle = .none

        let toggle = UISwitch()
        toggle.tag = indexPath.section * 100 + indexPath.row
        toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
        cell.accessoryView = toggle

        let defaults = sharedDefaults
        switch indexPath.section {
        case 0:
            cell.textLabel?.text = inputSettings[indexPath.row]
            toggle.isOn = defaults?.bool(forKey: SettingsKey.pinyinMixedEnabled) ?? false
        case 1:
            cell.textLabel?.text = wubiSettings[indexPath.row]
            if indexPath.row == 0 {
                toggle.isOn = defaults?.object(forKey: SettingsKey.autoCommitUnique4) as? Bool ?? true
            } else {
                toggle.isOn = defaults?.object(forKey: SettingsKey.autoCommitFirst5) as? Bool ?? true
            }
        case 2:
            cell.textLabel?.text = keyboardSettings[indexPath.row]
            toggle.isOn = defaults?.bool(forKey: SettingsKey.hapticEnabled) ?? false
        default:
            break
        }

        return cell
    }

    @objc private func toggleChanged(_ sender: UISwitch) {
        let section = sender.tag / 100
        let row = sender.tag % 100

        guard let defaults = sharedDefaults else { return }

        switch section {
        case 0:
            defaults.set(sender.isOn, forKey: SettingsKey.pinyinMixedEnabled)
        case 1:
            if row == 0 {
                defaults.set(sender.isOn, forKey: SettingsKey.autoCommitUnique4)
            } else {
                defaults.set(sender.isOn, forKey: SettingsKey.autoCommitFirst5)
            }
        case 2:
            defaults.set(sender.isOn, forKey: SettingsKey.hapticEnabled)
        default:
            break
        }
        defaults.synchronize()
    }
}
