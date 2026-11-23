import SwiftUI
import UIKit

@main
struct RugbyCamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

/// Tells iOS which ways the screen may turn right now.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return OrientationLock.allowed
    }
}

/// The camera screen stays sideways (charging port on the right). The
/// settings may also be used upright.
enum OrientationLock {
    static private(set) var allowed: UIInterfaceOrientationMask = .landscapeRight

    /// While the settings are open: upright or sideways, as the phone is held.
    static func allowUpright() {
        apply(UIInterfaceOrientationMask([.portrait, .landscapeRight]), turnTo: nil)
    }

    /// Back to the camera: sideways only, and turn the screen if it is upright.
    static func cameraOnly() {
        apply(.landscapeRight, turnTo: .landscapeRight)
    }

    private static func apply(_ mask: UIInterfaceOrientationMask, turnTo: UIInterfaceOrientationMask?) {
        allowed = mask
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            if let target = turnTo {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
            }
        }
    }
}
