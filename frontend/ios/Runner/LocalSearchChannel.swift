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
  /// Bumped per autocomplete call so a watchdog fired for one query does
  /// not settle a later one.
  private var autocompleteGeneration = 0
  /// The completer is a delegate, not a promise: nothing guarantees it
  /// ever calls back. Past this, Dart is answered with what there is so
  /// the spinner stops.
  private static let autocompleteTimeout: TimeInterval = 6

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

    // EVERY PENDING RESULT GETS ANSWERED.
    //
    // A fresh call used to overwrite `pendingAutocompleteResult`, and a
    // FlutterResult that is never invoked leaves the Dart side awaiting a
    // future that can never complete: the step's `_searching` flag stayed
    // true and its suggestion list never updated again for the rest of
    // the screen's life. The superseded call is now settled with what the
    // completer has, which the Dart side discards by request generation
    // anyway.
    finishAutocomplete(with: payload(for: lastResults))

    autocompleteGeneration += 1
    let generation = autocompleteGeneration
    pendingAutocompleteResult = result

    // Assigning the fragment it already holds produces NO delegate
    // callback, so this would otherwise hang forever. It happens more
    // than it sounds: an IME re-delivering the same text, or the user
    // deleting a character and typing it back.
    if completer.queryFragment == text {
      finishAutocomplete(with: payload(for: lastResults))
      return
    }

    completer.queryFragment = text

    DispatchQueue.main.asyncAfter(deadline: .now() + Self.autocompleteTimeout) {
      [weak self] in
      guard let self, self.autocompleteGeneration == generation else { return }
      self.finishAutocomplete(with: self.payload(for: self.lastResults))
    }
  }

  /// Hands `payload` to whichever autocomplete call is still waiting, and
  /// does nothing when none is — so every path here is safe to call more
  /// than once.
  private func finishAutocomplete(with payload: Any) {
    guard let pending = pendingAutocompleteResult else { return }
    pendingAutocompleteResult = nil
    pending(payload)
  }

  private func payload(for results: [MKLocalSearchCompletion]) -> [[String: String]] {
    results.map { ["title": $0.title, "subtitle": $0.subtitle] }
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
    finishAutocomplete(with: payload(for: lastResults))
  }

  func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
    // Empty, not an error. A completer failure is routine — no network
    // for a moment, a fragment it cannot parse — and the Dart side turns
    // an error into the same empty list anyway, after an exception it has
    // to catch on the main search path.
    lastResults = []
    finishAutocomplete(with: [[String: String]]())
  }
}
