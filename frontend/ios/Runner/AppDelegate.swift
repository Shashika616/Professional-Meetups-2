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
  }
}
