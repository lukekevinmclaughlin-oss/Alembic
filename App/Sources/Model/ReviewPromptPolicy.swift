import Foundation

enum ReviewPromptPolicy {
    private static let lastPromptDateKey = "reviewPrompt.lastDate"
    private static let lastPromptVersionKey = "reviewPrompt.lastVersion"
    private static let successfulRunsKey = "reviewPrompt.successfulRuns"
    private static let cooldown: TimeInterval = 120 * 24 * 60 * 60

    static func recordSuccessfulRun(defaults: UserDefaults = .standard) -> Bool {
        let runs = defaults.integer(forKey: successfulRunsKey) + 1
        defaults.set(runs, forKey: successfulRunsKey)
        guard runs >= 2 else { return false }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        guard defaults.string(forKey: lastPromptVersionKey) != version else { return false }
        if let lastDate = defaults.object(forKey: lastPromptDateKey) as? Date,
           Date().timeIntervalSince(lastDate) < cooldown {
            return false
        }
        defaults.set(Date(), forKey: lastPromptDateKey)
        defaults.set(version, forKey: lastPromptVersionKey)
        return true
    }
}
