import Foundation
import MetriaCore

/// Detects upward crossings of the menu bar alert thresholds between refresh ticks. Both
/// the sound alerter and the usage notifications consume this one source of truth so
/// their firing semantics cannot drift apart.
///
/// Thresholds come from the shared menu bar alert keys ("menuBarCautionThreshold",
/// "menuBarWarningThreshold", "menuBarCriticalThreshold") with the same fallbacks as
/// `MenuBarAlertSettings.default`.
@MainActor
final class ThresholdCrossingTracker {
    /// One upward threshold crossing, ready to be delivered by a consumer.
    struct Crossing: Equatable {
        let kind: ProviderKind
        let level: Level
        let threshold: Int
    }

    enum Level: Int, CaseIterable {
        case caution
        case warning
        case critical

        var thresholdKey: String {
            switch self {
            case .caution: return "menuBarCautionThreshold"
            case .warning: return "menuBarWarningThreshold"
            case .critical: return "menuBarCriticalThreshold"
            }
        }

        var fallbackThreshold: Int {
            switch self {
            case .caution: return MenuBarAlertSettings.default.cautionThreshold
            case .warning: return MenuBarAlertSettings.default.warningThreshold
            case .critical: return MenuBarAlertSettings.default.criticalThreshold
            }
        }

        var threshold: Double {
            Double(UserDefaults.standard.object(forKey: thresholdKey) as? Int ?? fallbackThreshold)
        }
    }

    /// Provider + level pair that has already announced itself; cleared when the percent
    /// falls back below that level's threshold, so a window reset can alert again.
    private struct FiredKey: Hashable {
        let kind: ProviderKind
        let level: Level
    }

    private var lastPercent: [ProviderKind: Double] = [:]
    private var fired: Set<FiredKey> = []

    /// Called on every `UsageStore.providers` publish. The first sighting of a provider
    /// only records a baseline. An upward crossing emits a `Crossing` once per provider
    /// and level until the percent falls back below that level's threshold (which re-arms
    /// it) or `reset()` is called. A provider losing its percent clears its baseline.
    func update(_ providers: [ProviderUsage]) -> [Crossing] {
        var crossings: [Crossing] = []
        var current: [ProviderKind: Double] = [:]
        for provider in providers {
            guard let percent = provider.primary?.percent else {
                lastPercent.removeValue(forKey: provider.kind)
                continue
            }
            current[provider.kind] = percent
            // A provider never seen before is baseline only: never alert on arrival.
            guard let previous = lastPercent[provider.kind] else { continue }
            for level in Level.allCases {
                let key = FiredKey(kind: provider.kind, level: level)
                if previous < level.threshold && percent >= level.threshold {
                    if !fired.contains(key) {
                        fired.insert(key)
                        crossings.append(
                            Crossing(
                                kind: provider.kind, level: level,
                                threshold: Int(level.threshold)))
                    }
                } else if previous >= level.threshold && percent < level.threshold {
                    // Re-arm: the level may fire again on the next upward crossing.
                    fired.remove(key)
                }
            }
        }
        lastPercent = current
        return crossings
    }

    /// Clears every fired marker, e.g. after thresholds changed in Settings.
    func reset() {
        fired.removeAll()
    }
}
