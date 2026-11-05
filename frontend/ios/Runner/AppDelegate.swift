import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Schedule flow's iOS location step (frontend/meetup-scheduling-
    // PLAN.md's 2026-08-18 platform-split addendum) — bridges
    // MKLocalSearchCompleter/MKLocalSearch to ios_local_search.dart.
    // apple_maps_flutter only renders the map; this is app-specific glue
    // code, not something that belongs in its own plugin package.
    LocalSearchChannel.register(with: engineBridge.applicationRegistrar.messenger())
    SecureScreenChannel.register(with: engineBridge.applicationRegistrar.messenger())
    AppIconChannel.register(with: engineBridge.applicationRegistrar.messenger())
  }
}

/// The home screen icon follows the app's theme (app_icon_service.dart): onyx
/// by default, white in the light theme. iOS shows its own alert when an app
/// changes its icon, so nothing is called when the icon is already right.
final class AppIconChannel {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "tiehere/app_icon", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "set", let mode = call.arguments as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      let wanted: String? = mode == "light" ? "AppIconLight" : nil
      let app = UIApplication.shared
      guard app.supportsAlternateIcons, app.alternateIconName != wanted else {
        result(nil)
        return
      }
      app.setAlternateIconName(wanted) { _ in result(nil) }
    }
  }
}

/// SecureScreen (lib/core/widgets/secure_screen.dart, #94).
///
/// iOS has no way to block screenshots. What it can protect is the
/// app-switcher snapshot, which the system takes as the app stops being
/// active: while a sensitive screen is up, the window is covered with a blur
/// at that moment and uncovered when the app is active again.
///
/// Kept in this file rather than its own so adding it needed no change to
/// the Xcode project.
final class SecureScreenChannel {
  private static let shared = SecureScreenChannel()
  private var enabled = false
  private var cover: UIView?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "tiehere/secure_screen", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "enable":
        shared.enabled = true
        result(nil)
      case "disable":
        shared.enabled = false
        shared.uncover()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let center = NotificationCenter.default
    center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
      shared.coverIfEnabled()
    }
    center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      shared.uncover()
    }
  }

  private func coverIfEnabled() {
    guard enabled, cover == nil, let window = Self.keyWindow() else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(blur)
    cover = blur
  }

  private func uncover() {
    cover?.removeFromSuperview()
    cover = nil
  }

  private static func keyWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }
}
