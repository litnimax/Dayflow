import Foundation

enum UpdatePreferences {
  static let automaticChecksKey = "dayflowAutomaticUpdateChecks"
  static let automaticCLIUpdatesKey = "dayflowAutomaticCLIUpdates"

  static func automaticChecksEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: automaticChecksKey)
  }

  static func automaticCLIUpdatesEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: automaticCLIUpdatesKey)
  }

  static func setAutomaticChecksEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: automaticChecksKey)
    prepareForLaunch(defaults: defaults)
  }

  /// Old releases silently opted everyone into Sparkle. Only the new explicit
  /// preference enables scheduled checks; installation always requires consent.
  static func prepareForLaunch(defaults: UserDefaults = .standard) {
    defaults.set(automaticChecksEnabled(defaults: defaults), forKey: "SUEnableAutomaticChecks")
    defaults.set(false, forKey: "SUAutomaticallyUpdate")
  }
}
