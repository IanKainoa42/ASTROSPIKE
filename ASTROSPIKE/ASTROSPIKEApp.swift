import SwiftUI

@main
struct ASTROSPIKEApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}

/// Which way up the app runs. The court is drawn for landscape, and that is
/// what every iPhone and iPad gets. The policy lives here rather than in
/// Info.plist because of iPhone Duo: its inner display ignores the app's
/// orientation list and turns with the device, and an app whose Info.plist
/// allows only landscape is shown there scaled up from a smaller window
/// instead of at the display's own size. So Info.plist allows every
/// orientation and these delegates refuse portrait at run time; the inner
/// display ignores the refusal and hands the app a portrait window, which
/// the layout accepts.
enum OrientationPolicy {
    /// `--any-orientation` lets a simulator turn to portrait: the only way to
    /// see the inner display's turned layout without an iPhone Duo.
    static var mask: UIInterfaceOrientationMask {
        ProcessInfo.processInfo.arguments.contains("--any-orientation") ? .all : .landscape
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// iOS 18 to 26 ask here. iOS 27 asks the scene delegate below instead.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationPolicy.mask
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask {
        OrientationPolicy.mask
    }
}
