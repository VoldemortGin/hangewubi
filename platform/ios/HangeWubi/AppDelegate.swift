import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    // On iOS 13+ with scene manifest, UIApplication manages windows via scenes.
    // On older iOS, fall back to AppDelegate.window.
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Scene-based setup is handled in SceneDelegate for iOS 13+.
        // For iOS 12 and below (if ever needed), set up the window here.
        if #unavailable(iOS 13.0) {
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = UINavigationController(rootViewController: MainViewController())
            window.makeKeyAndVisible()
            self.window = window
        }
        return true
    }

    // MARK: - UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}
