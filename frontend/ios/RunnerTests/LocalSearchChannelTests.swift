import Flutter
import MapKit
import XCTest

@testable import Runner

/// Guards the two ways `LocalSearchChannel.autocomplete` used to leave the
/// Dart side waiting on a future that could never complete. Both are
/// reproducible without MapKit answering anything, which is the point:
/// they are failures of the channel's own bookkeeping, not of the search.
final class LocalSearchChannelTests: XCTestCase {

  /// A call that is superseded before MapKit answers must still be
  /// answered. It used to be dropped: `pendingAutocompleteResult` was
  /// overwritten, and a FlutterResult that is never invoked strands the
  /// Dart await for the life of the screen — the step's spinner stayed on
  /// and its suggestion list never updated again.
  func testSupersededAutocompleteIsStillAnswered() {
    let channel = LocalSearchChannel()
    let answered = expectation(description: "first call answered")

    channel.handle(
      FlutterMethodCall(
        methodName: "autocomplete",
        arguments: ["text": "cof", "lat": 6.9271, "lon": 79.8612]
      )
    ) { _ in answered.fulfill() }

    // The next keystroke's call arrives before MapKit has said anything.
    channel.handle(
      FlutterMethodCall(
        methodName: "autocomplete",
        arguments: ["text": "coff", "lat": 6.9271, "lon": 79.8612]
      )
    ) { _ in }

    wait(for: [answered], timeout: 2)
  }

  /// Re-sending the fragment the completer already holds produces no
  /// delegate callback at all, so this call has to answer itself from the
  /// last batch rather than wait for one that will never come. It happens
  /// in ordinary use: an IME re-delivering the same text, or a character
  /// deleted and typed straight back.
  func testRepeatedQueryFragmentAnswersWithoutWaitingForTheCompleter() {
    let channel = LocalSearchChannel()
    let first = expectation(description: "first call answered")
    let repeated = expectation(description: "repeated call answered")

    let call = FlutterMethodCall(
      methodName: "autocomplete",
      arguments: ["text": "coffee", "lat": 6.9271, "lon": 79.8612]
    )

    channel.handle(call) { _ in first.fulfill() }
    // Settles the first (superseded) and then short-circuits on the
    // identical fragment.
    channel.handle(call) { result in
      XCTAssertNotNil(result as? [[String: String]])
      repeated.fulfill()
    }

    wait(for: [first, repeated], timeout: 2)
  }

  /// An unknown method is still a reply, not a silence.
  func testUnknownMethodIsReported() {
    let channel = LocalSearchChannel()
    let answered = expectation(description: "answered")
    channel.handle(FlutterMethodCall(methodName: "nope", arguments: nil)) {
      result in
      // FlutterMethodNotImplemented is a sentinel object, not a type.
      XCTAssertTrue((result as AnyObject) === (FlutterMethodNotImplemented as AnyObject))
      answered.fulfill()
    }
    wait(for: [answered], timeout: 2)
  }
}
