import AppKit
import XCTest

@testable import Dayflow

@MainActor
final class AppTerminationTests: XCTestCase {
  func testOrdinaryQuitTerminatesInsteadOfHidingTheApp() {
    let originalAllowed = AppDelegate.allowTermination
    let originalReason = AppDelegate.terminationReason
    defer {
      AppDelegate.allowTermination = originalAllowed
      AppDelegate.terminationReason = originalReason
    }
    AppDelegate.allowTermination = false
    AppDelegate.terminationReason = "unknown"
    let application = NSApplication.shared
    let policy = application.activationPolicy()

    let reply = AppDelegate().applicationShouldTerminate(application)

    XCTAssertEqual(reply, .terminateNow)
    XCTAssertEqual(AppDelegate.terminationReason, "user_quit")
    XCTAssertEqual(application.activationPolicy(), policy)
  }

  func testExplicitQuitPreservesItsReason() {
    let originalAllowed = AppDelegate.allowTermination
    let originalReason = AppDelegate.terminationReason
    defer {
      AppDelegate.allowTermination = originalAllowed
      AppDelegate.terminationReason = originalReason
    }
    let delegate = AppDelegate()

    for reason in ["menu_bar_quit", "update_install", "power_off_or_logout"] {
      AppDelegate.permitTermination(reason: reason)
      XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateNow)
      XCTAssertEqual(AppDelegate.terminationReason, reason)
    }
  }
}
