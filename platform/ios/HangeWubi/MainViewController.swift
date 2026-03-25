import UIKit

class MainViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "函戈五笔"
        view.backgroundColor = .systemGroupedBackground

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        // App icon / title area
        let iconLabel = UILabel()
        iconLabel.text = "函"
        iconLabel.font = UIFont.systemFont(ofSize: 64, weight: .bold)
        iconLabel.textAlignment = .center
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconLabel)

        let titleLabel = UILabel()
        titleLabel.text = "函戈五笔"
        titleLabel.font = UIFont.systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        let versionLabel = UILabel()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        versionLabel.text = "版本 \(version)"
        versionLabel.font = UIFont.systemFont(ofSize: 14)
        versionLabel.textColor = .secondaryLabel
        versionLabel.textAlignment = .center
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(versionLabel)

        // Instructions card
        let cardView = makeCardView()
        contentView.addSubview(cardView)

        let instructionTitle = UILabel()
        instructionTitle.text = "如何启用键盘"
        instructionTitle.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
        instructionTitle.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(instructionTitle)

        let steps = [
            "1. 打开「设置」应用",
            "2. 进入「通用」→「键盘」→「键盘」",
            "3. 点击「添加新键盘...」",
            "4. 在第三方键盘中选择「函戈五笔」",
        ]

        let stepsLabel = UILabel()
        stepsLabel.text = steps.joined(separator: "\n")
        stepsLabel.font = UIFont.systemFont(ofSize: 16)
        stepsLabel.numberOfLines = 0
        stepsLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(stepsLabel)

        // Open Settings button
        let openSettingsButton = UIButton(type: .system)
        openSettingsButton.setTitle("打开系统设置", for: .normal)
        openSettingsButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .medium)
        openSettingsButton.backgroundColor = .systemBlue
        openSettingsButton.setTitleColor(.white, for: .normal)
        openSettingsButton.layer.cornerRadius = 12
        openSettingsButton.translatesAutoresizingMaskIntoConstraints = false
        openSettingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        contentView.addSubview(openSettingsButton)

        // Description
        let descLabel = UILabel()
        descLabel.text = "函戈五笔是一款开源的五笔输入法，基于 86 版五笔编码，支持自动上屏、候选词选择等功能。所有数据均在本地处理，不需要网络权限。"
        descLabel.font = UIFont.systemFont(ofSize: 14)
        descLabel.textColor = .secondaryLabel
        descLabel.numberOfLines = 0
        descLabel.textAlignment = .center
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(descLabel)

        NSLayoutConstraint.activate([
            iconLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 40),
            iconLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            titleLabel.topAnchor.constraint(equalTo: iconLabel.bottomAnchor, constant: 8),
            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            versionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            versionLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            cardView.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 32),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            instructionTitle.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 20),
            instructionTitle.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            instructionTitle.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),

            stepsLabel.topAnchor.constraint(equalTo: instructionTitle.bottomAnchor, constant: 12),
            stepsLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            stepsLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            stepsLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -20),

            openSettingsButton.topAnchor.constraint(equalTo: cardView.bottomAnchor, constant: 24),
            openSettingsButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            openSettingsButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            openSettingsButton.heightAnchor.constraint(equalToConstant: 50),

            descLabel.topAnchor.constraint(equalTo: openSettingsButton.bottomAnchor, constant: 32),
            descLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            descLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
            descLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40),
        ])
    }

    private func makeCardView() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    @objc private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
