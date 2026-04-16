import UIKit

/// 按键按下时浮出的放大预览气泡（苹果键盘签名特性）
final class KeyPreviewView: UIView {

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = Self.bgColor
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 5

        label.textAlignment = .center
        label.textColor = .label
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 在指定按键正上方显示放大字符
    /// - Parameters:
    ///   - keyFrame: 按键在 KeyboardView 坐标系中的 frame
    ///   - character: 放大展示的字符
    ///   - isIPad: iPad 用更大字号
    func show(over keyFrame: CGRect, character: String, isIPad: Bool) {
        label.text = character
        label.font = .systemFont(ofSize: isIPad ? 38 : 32, weight: .regular)

        let width = max(keyFrame.width * 1.35, keyFrame.width + 12)
        let height = keyFrame.height * 1.55
        let x = keyFrame.midX - width / 2
        let y = keyFrame.minY - height + 4
        frame = CGRect(x: x, y: y, width: width, height: height)
        isHidden = false
    }

    func hide() {
        isHidden = true
    }

    private static let bgColor: UIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.55, green: 0.55, blue: 0.56, alpha: 1.0)
            : .white
    }
}
