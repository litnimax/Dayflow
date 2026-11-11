import AppKit
import SwiftUI
import XCTest

@testable import Dayflow

@MainActor
final class LocalFlowSessionTests: XCTestCase {
  private var wasEnabled = true

  override func setUp() async throws {
    wasEnabled = FlowAgentSettings.shared.agentEnabled
    FlowAgentSettings.shared.agentEnabled = false
    FlowSessionMirror.shared.apply(.idle)
    FlowSessionTimeline.shared.clear()
  }

  override func tearDown() async throws {
    FlowSessionMirror.shared.apply(.idle)
    FlowSessionTimeline.shared.clear()
    FlowAgentSettings.shared.agentEnabled = wasEnabled
  }

  func testSessionStartsWithoutAccountOrWebBridge() {
    let mirror = FlowSessionMirror.shared
    XCTAssertNil(mirror.webBridge)
    mirror.startSession(
      titles: ["  Ship the fix  ", "", "Review tests"], minutes: 25,
      alertStyle: .quiet)
    XCTAssertEqual(mirror.snapshot.phase, .active)
    XCTAssertEqual(mirror.snapshot.goals, ["Ship the fix", "Review tests"])
    XCTAssertEqual(mirror.snapshot.sessionEndsAt! - mirror.snapshot.sessionStartedAt!, 1500)
    XCTAssertEqual(FlowNativeSnapshot.loadPersisted(), mirror.snapshot)
  }

  func testBlankTasksDoNotStartSession() {
    FlowSessionMirror.shared.startSession(titles: [" \n"], minutes: 25, alertStyle: .friendly)
    XCTAssertEqual(FlowSessionMirror.shared.snapshot.phase, .idle)
  }

  func testMenuControlsWorkWithNoWebViewAndDisabledAgent() {
    let mirror = FlowSessionMirror.shared
    mirror.startSession(titles: ["Work"], minutes: 50, alertStyle: .friendly)
    mirror.menuBarControl("break", minutes: 5)
    XCTAssertEqual(mirror.snapshot.phase, .onBreak)
    XCTAssertEqual(FlowSessionTimeline.shared.breaks.count, 1)
    mirror.menuBarControl("resume")
    XCTAssertEqual(mirror.snapshot.phase, .active)
    XCTAssertNil(mirror.snapshot.breakEndsAt)
    XCTAssertNotNil(FlowSessionTimeline.shared.breaks.first?.end)
    mirror.menuBarControl("end")
    XCTAssertEqual(mirror.snapshot.phase, .ended)
    XCTAssertNotNil(mirror.snapshot.sessionEndedAt)
    XCTAssertEqual(FlowNativeSnapshot.loadPersisted(), mirror.snapshot)
  }

  func testCompletingTasksIsPersistedAndIdempotent() {
    let mirror = FlowSessionMirror.shared
    mirror.startSession(titles: ["One", "Two"], minutes: 25, alertStyle: .quiet)
    let first = mirror.snapshot.goalTasks![0]
    mirror.agentCompletedGoals([first])
    mirror.agentCompletedGoals([first])
    XCTAssertEqual(mirror.snapshot.completedTasks, [first])
    XCTAssertEqual(mirror.snapshot.goals, ["Two"])
    XCTAssertEqual(FlowNativeSnapshot.loadPersisted(), mirror.snapshot)
  }

  func testBreakDeadlineResumesSessionLocally() {
    let mirror = FlowSessionMirror.shared
    mirror.startSession(titles: ["Work"], minutes: 50, alertStyle: .quiet)
    mirror.menuBarControl("break", minutes: 5)
    var snapshot = mirror.snapshot
    snapshot.breakEndsAt = Int(Date().timeIntervalSince1970) - 1
    mirror.apply(snapshot)
    mirror.handleDeadline()
    XCTAssertEqual(mirror.snapshot.phase, .active)
    XCTAssertNil(mirror.snapshot.breakEndsAt)
    XCTAssertNotNil(FlowSessionTimeline.shared.breaks.first?.end)
  }

  func testSessionDeadlineAlsoEndsDuringBreak() {
    let mirror = FlowSessionMirror.shared
    mirror.startSession(titles: ["Work"], minutes: 15, alertStyle: .quiet)
    mirror.menuBarControl("break", minutes: 30)
    var snapshot = mirror.snapshot
    snapshot.sessionEndsAt = Int(Date().timeIntervalSince1970) - 1
    mirror.apply(snapshot)
    mirror.handleDeadline()
    XCTAssertEqual(mirror.snapshot.phase, .ended)
    XCTAssertNil(mirror.snapshot.breakEndsAt)
    XCTAssertEqual(mirror.overlay, .sessionEnded)
    XCTAssertNotNil(FlowSessionTimeline.shared.breaks.first?.end)
  }

  func testStartingAgainDoesNotReplaceActiveSession() {
    let mirror = FlowSessionMirror.shared
    mirror.startSession(titles: ["Original"], minutes: 25, alertStyle: .quiet)
    let original = mirror.snapshot
    mirror.startSession(titles: ["Replacement"], minutes: 50, alertStyle: .friendly)
    XCTAssertEqual(mirror.snapshot, original)
  }

  func testLegacySnapshotStillDecodesWithoutLocalFields() throws {
    let legacy = Data(#"{"phase":"idle","alertStyle":"friendly","alwaysOn":false}"#.utf8)
    let snapshot = try JSONDecoder().decode(FlowNativeSnapshot.self, from: legacy)
    XCTAssertEqual(snapshot.phase, .idle)
    XCTAssertNil(snapshot.completedTasks)
    XCTAssertNil(snapshot.sessionEndedAt)
  }

  func testContinueKeepsSessionAndCompletedTasks() {
    let mirror = FlowSessionMirror.shared
    mirror.startSession(titles: ["Work"], minutes: 25, alertStyle: .quiet)
    let task = mirror.snapshot.goalTasks![0]
    mirror.completeTasks(ids: [task.id])
    let id = mirror.snapshot.sessionID
    let started = mirror.snapshot.sessionStartedAt
    mirror.menuBarControl("end")
    mirror.continueSession()
    XCTAssertEqual(mirror.snapshot.phase, .active)
    XCTAssertEqual(mirror.snapshot.sessionID, id)
    XCTAssertEqual(mirror.snapshot.sessionStartedAt, started)
    XCTAssertEqual(mirror.snapshot.completedTasks, [task])
    XCTAssertNil(mirror.snapshot.sessionEndedAt)
  }

  func testNewSessionAtSameTimeDoesNotReusePreviousObservations() {
    let timeline = FlowSessionTimeline.shared
    let now = Date()
    timeline.begin(sessionStartedAt: now, sessionID: "first")
    timeline.observe(offTask: false, front: .none, reason: "Working")
    timeline.begin(sessionStartedAt: now, sessionID: "first")
    XCTAssertEqual(timeline.observations.count, 1)
    timeline.begin(sessionStartedAt: now, sessionID: "second")
    XCTAssertTrue(timeline.observations.isEmpty)
  }

  func testNativeFlowScreenRendersWithoutWebContent() throws {
    let view = NSHostingView(rootView: FlowView().environment(\.colorScheme, .light))
    view.appearance = NSAppearance(named: .aqua)
    view.frame = NSRect(x: 0, y: 0, width: 1000, height: 760)
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    XCTAssertGreaterThan(png.count, 1000)
    if let directory = ProcessInfo.processInfo.environment["FLOW_SNAPSHOT_DIR"] {
      try png.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("local-flow-setup.png"))
    }
  }
}
