import Foundation
import MetriaCore
import UserNotifications

/// Posts a macOS notification once when a provider's usage percent crosses one of the
/// menu bar alert thresholds upward between refresh ticks.
///
/// Unlike the sound alerter, notifications ignore the manual sound mute and the
/// login-session activity on purpose: Focus / Do Not Disturb filtering is macOS's job,
/// and that awareness is the reason this feature exists. Locked-screen banner behavior
/// is the system's too. Crossings seen while the feature or a level is switched off are
/// discarded with no deferral.
///
/// UserDefaults keys read and written here (the Settings notifications block shares them):
/// - "usageNotificationsEnabled" (Bool, default `false`): master switch.
/// - "usageNotificationsCautionEnabled" / "usageNotificationsWarningEnabled" /
///   "usageNotificationsCriticalEnabled" (Bool, default `true`): per-level switches.
///
/// Thresholds come from the shared menu bar alert keys ("menuBarCautionThreshold",
/// "menuBarWarningThreshold", "menuBarCriticalThreshold") with the same fallbacks as
/// `MenuBarAlertSettings.default`, read through `ThresholdCrossingTracker`.
@MainActor
final class UsageNotifier {
    private static let enabledKey = "usageNotificationsEnabled"

    private typealias Crossing = ThresholdCrossingTracker.Crossing

    private let tracker = ThresholdCrossingTracker()
    /// Refreshed from the notification center before every posting tick, so changes made
    /// in System Settings stay honest.
    private(set) var isAuthorized = false

    /// Asks the user for notification permission when the feature is switched on. The
    /// system only shows the prompt while the status is `.notDetermined`, so repeated
    /// calls are safe — and they let a user recover a prompt they missed the first time
    /// by toggling the feature off and on again.
    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Called when thresholds change in Settings so every level can fire again.
    func settingsDidChange() {
        tracker.reset()
    }

    /// Called on every `UsageStore.providers` publish. The first snapshot of a provider
    /// only records a baseline; later snapshots post at most one notification per
    /// provider, for its most severe upward crossing.
    func process(_ providers: [ProviderUsage]) {
        let crossings = tracker.update(providers).filter { $0.level.isNotificationEnabled }
        guard isEnabled, !crossings.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let activeCrossings = crossings.filter { $0.level.isNotificationEnabled }
            guard self.isEnabled, !activeCrossings.isEmpty else { return }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self.isAuthorized = settings.authorizationStatus == .authorized
            guard self.isAuthorized, self.isEnabled else { return }
            let currentCrossings = activeCrossings.filter { $0.level.isNotificationEnabled }
            guard !currentCrossings.isEmpty else { return }
            await self.post(currentCrossings)
        }
    }

    /// Whether the master switch in Settings is on.
    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    /// One notification per provider per tick; the most severe level wins when usage
    /// jumps across several thresholds at once. Banners group per provider via
    /// `threadIdentifier`, carry no sound (the sound alerts feature owns audio), and use
    /// the default interruption level so Focus keeps working.
    private func post(_ crossings: [Crossing]) async {
        // Keep provider order; the most severe crossing wins within one provider.
        var bestPerKind: [ProviderKind: Crossing] = [:]
        var kindsInOrder: [ProviderKind] = []
        for crossing in crossings {
            if let current = bestPerKind[crossing.kind] {
                if crossing.level.rawValue > current.level.rawValue {
                    bestPerKind[crossing.kind] = crossing
                }
            } else {
                bestPerKind[crossing.kind] = crossing
                kindsInOrder.append(crossing.kind)
            }
        }
        let center = UNUserNotificationCenter.current()
        for kind in kindsInOrder {
            guard let crossing = bestPerKind[kind] else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Metria"
            content.body = "\(kind.rawValue) reached \(crossing.threshold)% of its usage limit"
            content.threadIdentifier = kind.rawValue
            let request = UNNotificationRequest(
                identifier: "metria.usage.\(kind.rawValue).\(crossing.level.rawValue)",
                content: content,
                trigger: nil)
            try? await center.add(request)
        }
    }
}

/// Notification switches for the shared crossing levels. Threshold values live in
/// `ThresholdCrossingTracker.Level`; only the per-level notification toggles belong here.
private extension ThresholdCrossingTracker.Level {
    var notificationEnabledKey: String {
        switch self {
        case .caution: return "usageNotificationsCautionEnabled"
        case .warning: return "usageNotificationsWarningEnabled"
        case .critical: return "usageNotificationsCriticalEnabled"
        }
    }

    var isNotificationEnabled: Bool {
        UserDefaults.standard.object(forKey: notificationEnabledKey) as? Bool ?? true
    }
}
