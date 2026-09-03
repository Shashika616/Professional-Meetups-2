import Flutter
import MapKit

/// Native side of `ios_local_search.dart` — bridges MapKit's
/// `MKLocalSearchCompleter`/`MKLocalSearch` to Dart over a `MethodChannel`,
/// since `apple_maps_flutter` only renders the map and doesn't expose
/// MapKit's search APIs itself (frontend/meetup-scheduling-PLAN.md's
/// 2026-08-18 platform-split addendum, Step 2).
///
/// A raw `MKLocalSearchCompletion` can't cross the channel boundary, so
/// `autocomplete` sends back lightweight title/subtitle pairs and this
/// class keeps the underlying completions in `lastResults`; `resolveCompletion`
/// looks one up by index and runs the second `MKLocalSearch` MapKit itself
/// requires to turn a completion into real coordinates.
final class LocalSearchChannel: NSObject, MKLocalSearchCompleterDelegate {
  private let completer = MKLocalSearchCompleter()
  private var pendingAutocompleteResult: FlutterResult?
  private var lastResults: [MKLocalSearchCompletion] = []

  override init() {
    super.init()
    completer.delegate = self
    completer.resultTypes = [.pointOfInterest, .address]
  }

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "professionalconnections/ios_local_search",
      binaryMessenger: messenger
    )
    let instance = LocalSearchChannel()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "autocomplete":
      handleAutocomplete(call, result: result)
    case "resolveCompletion":
      handleResolveCompletion(call, result: result)
    case "search":
      handleSearch(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleAutocomplete(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let text = args["text"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "text is required", details: nil))
      return
    }
    if let lat = args["lat"] as? Double, let lon = args["lon"] as? Double {
      completer.region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
      )
    }
    // A fresh call replaces whatever the previous one was waiting for —
    // Dart's own debounce already ensures only the latest query matters,
    // so an in-flight completer callback for a superseded query is simply
    // dropped rather than replied to twice.
    pendingAutocompleteResult = result
    completer.queryFragment = text
  }

  private func handleResolveCompletion(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let index = args["index"] as? Int,
      index >= 0, index < lastResults.count
    else {
      result(FlutterError(code: "bad_index", message: "invalid completion index", details: nil))
      return
    }
    let completion = lastResults[index]
    let request = MKLocalSearch.Request(completion: completion)
    MKLocalSearch(request: request).start { response, error in
      guard let item = response?.mapItems.first else {
        result(
          FlutterError(
            code: "no_result", message: error?.localizedDescription ?? "no result", details: nil))
        return
      }
      let coordinate = item.placemark.coordinate
      let label =
        completion.subtitle.isEmpty
        ? completion.title : "\(completion.title), \(completion.subtitle)"
      result(["lat": coordinate.latitude, "lon": coordinate.longitude, "label": label])
    }
  }

  private func handleSearch(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let text = args["text"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "text is required", details: nil))
      return
    }
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = text
    if let lat = args["lat"] as? Double, let lon = args["lon"] as? Double {
      request.region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
      )
    }
    MKLocalSearch(request: request).start { response, error in
      guard let item = response?.mapItems.first else {
        result(
          FlutterError(
            code: "no_result", message: error?.localizedDescription ?? "no result", details: nil))
        return
      }
      let coordinate = item.placemark.coordinate
      result(["lat": coordinate.latitude, "lon": coordinate.longitude, "label": item.name ?? text])
    }
  }

  // MARK: - MKLocalSearchCompleterDelegate

  func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
    lastResults = completer.results
    let payload = lastResults.map { ["title": $0.title, "subtitle": $0.subtitle] }
    pendingAutocompleteResult?(payload)
    pendingAutocompleteResult = nil
  }

  func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
    pendingAutocompleteResult?(
      FlutterError(code: "completer_failed", message: error.localizedDescription, details: nil))
    pendingAutocompleteResult = nil
  }
}
