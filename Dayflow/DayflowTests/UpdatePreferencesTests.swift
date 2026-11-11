import XCTest

@testable import Dayflow

final class UpdatePreferencesTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite: String!

  override func setUp() {
    suite = "UpdatePreferencesTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
  }

  func testFreshInstallDoesNotOptIntoAnyAutomaticUpdates() {
    UpdatePreferences.prepareForLaunch(defaults: defaults)
    XCTAssertFalse(UpdatePreferences.automaticChecksEnabled(defaults: defaults))
    XCTAssertFalse(UpdatePreferences.automaticCLIUpdatesEnabled(defaults: defaults))
    XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false)
    XCTAssertEqual(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool, false)
  }

  func testLegacySparkleOptInDoesNotOverrideNewDefault() {
    defaults.set(true, forKey: "SUEnableAutomaticChecks")
    defaults.set(true, forKey: "SUAutomaticallyUpdate")
    UpdatePreferences.prepareForLaunch(defaults: defaults)
    XCTAssertFalse(defaults.bool(forKey: "SUEnableAutomaticChecks"))
    XCTAssertFalse(defaults.bool(forKey: "SUAutomaticallyUpdate"))
  }

  func testExplicitCheckOptInSurvivesRelaunchWithoutEnablingDownloads() {
    UpdatePreferences.setAutomaticChecksEnabled(true, defaults: defaults)
    UpdatePreferences.prepareForLaunch(defaults: defaults)
    XCTAssertTrue(UpdatePreferences.automaticChecksEnabled(defaults: defaults))
    XCTAssertTrue(defaults.bool(forKey: "SUEnableAutomaticChecks"))
    XCTAssertFalse(defaults.bool(forKey: "SUAutomaticallyUpdate"))
    XCTAssertFalse(UpdatePreferences.automaticCLIUpdatesEnabled(defaults: defaults))
  }

  func testTurningChecksOffPersists() {
    UpdatePreferences.setAutomaticChecksEnabled(true, defaults: defaults)
    UpdatePreferences.setAutomaticChecksEnabled(false, defaults: defaults)
    UpdatePreferences.prepareForLaunch(defaults: defaults)
    XCTAssertFalse(UpdatePreferences.automaticChecksEnabled(defaults: defaults))
    XCTAssertFalse(defaults.bool(forKey: "SUEnableAutomaticChecks"))
  }

  func testCLIUpdatesRequireSeparateExplicitOptIn() {
    defaults.set(true, forKey: UpdatePreferences.automaticCLIUpdatesKey)
    UpdatePreferences.prepareForLaunch(defaults: defaults)
    XCTAssertTrue(UpdatePreferences.automaticCLIUpdatesEnabled(defaults: defaults))
    XCTAssertFalse(UpdatePreferences.automaticChecksEnabled(defaults: defaults))
    defaults.set(false, forKey: UpdatePreferences.automaticCLIUpdatesKey)
    XCTAssertFalse(UpdatePreferences.automaticCLIUpdatesEnabled(defaults: defaults))
  }
}
