import UIKit

/// 通过 App Group 共享的设置键名
enum SettingsKey {
    static let suiteName = "group.com.hangewubi.app"
    static let pinyinMixedEnabled = "pinyin_mixed_enabled"
    static let autoCommitUnique4 = "auto_commit_unique_4"
    static let autoCommitFirst5 = "auto_commit_first_5"
    static let candidateCount = "candidate_count"
}

class SettingsViewController: UITableViewController {

    private let sections = ["输入设置", "五笔设置"]
    private let inputSettings = ["五笔拼音混输"]
    private let wubiSettings = ["四码唯一自动上屏", "五码首选自动上屏"]

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
        if section == 0 {
            return "开启后可在输入五笔编码的同时匹配拼音候选词，五笔结果始终优先显示。"
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? inputSettings.count : wubiSettings.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.selectionStyle = .none

        let toggle = UISwitch()
        toggle.tag = indexPath.section * 100 + indexPath.row
        toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
        cell.accessoryView = toggle

        let defaults = sharedDefaults
        if indexPath.section == 0 {
            cell.textLabel?.text = inputSettings[indexPath.row]
            toggle.isOn = defaults?.bool(forKey: SettingsKey.pinyinMixedEnabled) ?? false
        } else {
            cell.textLabel?.text = wubiSettings[indexPath.row]
            if indexPath.row == 0 {
                toggle.isOn = defaults?.object(forKey: SettingsKey.autoCommitUnique4) as? Bool ?? true
            } else {
                toggle.isOn = defaults?.object(forKey: SettingsKey.autoCommitFirst5) as? Bool ?? true
            }
        }

        return cell
    }

    @objc private func toggleChanged(_ sender: UISwitch) {
        let section = sender.tag / 100
        let row = sender.tag % 100

        guard let defaults = sharedDefaults else { return }

        if section == 0 {
            defaults.set(sender.isOn, forKey: SettingsKey.pinyinMixedEnabled)
        } else if row == 0 {
            defaults.set(sender.isOn, forKey: SettingsKey.autoCommitUnique4)
        } else {
            defaults.set(sender.isOn, forKey: SettingsKey.autoCommitFirst5)
        }
        defaults.synchronize()
    }
}
