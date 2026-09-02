import Combine
import Foundation

public struct UsageWindow: Equatable, Identifiable {
    public let title: String
    public let percent: Double
    public let resetDate: Date?
    /// What the window costs, in cents, when the provider measures money rather than a
    /// bare percentage (Cursor). Present as a pair or not at all.
    public let usedCents: Double?
    public let limitCents: Double?

    public var id: String { title }

    public init(title: String, percent: Double, resetDate: Date?, usedCents: Double? = nil, limitCents: Double? = nil) {
        self.title = title
        self.percent = percent
        self.resetDate = resetDate
        self.usedCents = usedCents
        self.limitCents = limitCents
    }

    public func spendParts(_ display: SpendDisplay) -> SpendParts {
        SpendFormat.parts(usedCents: usedCents, limitCents: limitCents, display: display)
    }
}

/// How a window that carries spend amounts prints its magnitude. Persisted by raw value
/// under the `spendDisplay` defaults key on macOS, and in the shared App Group on iOS.
public enum SpendDisplay: String, CaseIterable, Identifiable {
    case percent
    case dollars
    case both

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .percent: "Percentage"
        case .dollars: "Dollars"
        case .both: "Both"
        }
    }
}

/// Which halves of a readout to draw: the percentage, the money, or both.
public struct SpendParts: Equatable {
    public let showsPercent: Bool
    public let spend: String?
}

public enum SpendFormat {
    public static let defaultsKey = "spendDisplay"

    /// The persisted choice, defaulting to the same `.both` every `@AppStorage` binding
    /// on this key declares. iOS passes the App Group's suite so the widget extension and
    /// the app read one setting.
    public static func display(in defaults: UserDefaults) -> SpendDisplay {
        defaults.string(forKey: defaultsKey).flatMap(SpendDisplay.init(rawValue:)) ?? .both
    }

    /// Cursor reports cents. Whole dollars drop the decimals so the common case reads as
    /// money ("$130") instead of accounting ("$130.00").
    public static func amount(cents: Double) -> String {
        let dollars = cents / 100
        return String(format: dollars == dollars.rounded() ? "$%.0f" : "$%.2f", dollars)
    }

    /// The money half of a readout — "$130 / $250" — or nil for a provider that only ever
    /// reports a percentage.
    public static func text(usedCents: Double?, limitCents: Double?) -> String? {
        guard let usedCents, let limitCents else { return nil }
        return "\(amount(cents: usedCents)) / \(amount(cents: limitCents))"
    }

    /// A window without amounts always keeps its percentage, so choosing dollars never
    /// blanks out Claude, Codex, or OpenCode Go.
    public static func parts(usedCents: Double?, limitCents: Double?, display: SpendDisplay) -> SpendParts {
        guard let spend = text(usedCents: usedCents, limitCents: limitCents) else { return SpendParts(showsPercent: true, spend: nil) }
        return SpendParts(showsPercent: display != .dollars, spend: display == .percent ? nil : spend)
    }
}

public enum ProviderKind: String, CaseIterable, Identifiable, Hashable {
    case claude = "Claude"
    case codex = "Codex"
    case openCodeGo = "OpenCode Go"
    case cursor = "Cursor"

    public var id: String { rawValue }
}

public struct ProviderUsage: Identifiable, Equatable {
    public let kind: ProviderKind
    public let accountLabel: String?
    /// The account's subscription tier (e.g. "Max", "Pro", "Plus"), shown in place of the
    /// generic "Connected" badge when a provider can resolve it.
    public let planLabel: String?
    public var windows: [UsageWindow]
    public var updatedAt: Date?
    public var error: String?

    public var id: ProviderKind { kind }
    public var primary: UsageWindow? { windows.first }

    public init(kind: ProviderKind, accountLabel: String? = nil, planLabel: String? = nil, windows: [UsageWindow], updatedAt: Date?, error: String?) {
        self.kind = kind
        self.accountLabel = accountLabel
        self.planLabel = planLabel
        self.windows = windows
        self.updatedAt = updatedAt
        self.error = error
    }
}

public enum ProviderFetchResult: Equatable {
    case loaded(ProviderUsage)
    case empty(ProviderUsage)
    case failed(ProviderKind, String, retryAfter: TimeInterval?)
}

public protocol UsageProvider {
    var kind: ProviderKind { get }
    var isAvailable: Bool { get }
    var setupHint: String { get }
    var usageWindowTitles: [String] { get }
    func fetch() async -> ProviderFetchResult
}

@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var providers: [ProviderUsage] = []
    @Published public var refreshInterval = 300.0 {
        didSet {
            guard refreshInterval != oldValue else { return }
            rescheduleTimer()
        }
    }
    @Published public private(set) var enabledProviderKinds: Set<ProviderKind>
    @Published public private(set) var hiddenWindowTitlesByProvider: [ProviderKind: Set<String>] = [:]
    /// The providers to display, in `ProviderKind` order, backfilled with an empty
    /// placeholder for any enabled provider that hasn't reported usage yet. Computed once
    /// per underlying change instead of by every view that needs it on every render.
    @Published public private(set) var visibleProviders: [ProviderUsage] = []

    private let sources: [any UsageProvider]
    private let availableProviderKinds: Set<ProviderKind>
    private let defaults: UserDefaults
    private var refreshOperation: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var retryTasks: [ProviderKind: Task<Void, Never>] = [:]
    private var isRefreshing = false
    private let enabledProvidersKey = "enabledProviderKinds"
    private let hiddenWindowTitlesKey = "hiddenUsageWindowTitles"
    private let cachedUsageKey = "cachedProviderUsage"
    private let knownProvidersKey = "knownProviderKinds"

    private struct CachedUsage: Codable {
        struct CachedWindow: Codable {
            let title: String
            let percent: Double
            let resetDate: Date?
        }

        let kind: String
        let windows: [CachedWindow]
        let updatedAt: Date?
    }

    /// Provider kinds that existed before the `knownProviderKinds` migration
    /// key was introduced. Existing installs treat these as already known so
    /// that only genuinely new kinds (added after this point) get
    /// auto-enabled; see `Providers auto-enablement migration` below.
    private static let legacyProviderKinds: Set<ProviderKind> = [.claude, .codex, .openCodeGo]

    public init(providers: [any UsageProvider], defaults: UserDefaults = .standard) {
        self.sources = providers
        self.defaults = defaults
        // `nil` (key never written) means "never configured — default to every detected
        // provider enabled". An empty array is a real, intentional choice (the user
        // disabled every provider) and must not be re-interpreted as "unconfigured" on the
        // next launch, or a fully-disabled setup would silently re-enable itself.
        let hasSavedKinds = defaults.object(forKey: enabledProvidersKey) != nil
        let savedKinds = (defaults.array(forKey: enabledProvidersKey) as? [String] ?? [])
            .compactMap(ProviderKind.init(rawValue:))
        let availableKinds = Set(providers.filter(\.isAvailable).map(\.kind))
        availableProviderKinds = availableKinds
        let knownKinds = (defaults.array(forKey: knownProvidersKey) as? [String])
            .map { Set($0.compactMap(ProviderKind.init(rawValue:))) } ?? Self.legacyProviderKinds
        let newlyAvailableKinds = availableKinds.subtracting(knownKinds)
        enabledProviderKinds = hasSavedKinds ? Set(savedKinds).union(newlyAvailableKinds) : availableKinds
        defaults.set(knownKinds.union(availableKinds).map(\.rawValue), forKey: knownProvidersKey)
        if hasSavedKinds, !newlyAvailableKinds.isEmpty {
            defaults.set(enabledProviderKinds.map(\.rawValue), forKey: enabledProvidersKey)
        }
        self.providers = Self.loadCachedUsage(from: defaults, key: cachedUsageKey)
            .filter { availableKinds.contains($0.kind) && enabledProviderKinds.contains($0.kind) }
        let savedHidden = (defaults.dictionary(forKey: hiddenWindowTitlesKey) as? [String: [String]]) ?? [:]
        hiddenWindowTitlesByProvider = savedHidden.reduce(into: [ProviderKind: Set<String>]()) { result, entry in
            guard let kind = ProviderKind(rawValue: entry.key) else { return }
            result[kind] = Set(entry.value)
        }
        updateVisibleProviders()
    }

    private func updateVisibleProviders() {
        visibleProviders = ProviderKind.allCases
            .compactMap { kind in
                guard enabledProviderKinds.contains(kind),
                    availableProviderKinds.contains(kind),
                    let usage = providers.first(where: { $0.kind == kind }),
                    // Gate on having ever produced real usage data, not on being
                    // error-free: a provider that's rate-limited or hit a transient
                    // failure still has legitimate data to show (with its error surfaced
                    // alongside it). Only a provider that has never returned anything —
                    // e.g. one that merely looks configured (a leftover local file) but
                    // has no valid session — should be excluded entirely.
                    !usage.windows.isEmpty
                else { return nil }
                return usage
            }
    }

    public func isProviderAvailable(_ kind: ProviderKind) -> Bool {
        sources.first(where: { $0.kind == kind })?.isAvailable ?? false
    }

    public func setupHint(for kind: ProviderKind) -> String? {
        sources.first(where: { $0.kind == kind })?.setupHint
    }

    public func usageWindowTitles(for kind: ProviderKind) -> [String] {
        sources.first(where: { $0.kind == kind })?.usageWindowTitles ?? []
    }

    public func diagnosis(for kind: ProviderKind) -> String {
        guard let source = sources.first(where: { $0.kind == kind }) else {
            return "This provider is not registered in Metria."
        }

        var details = [source.isAvailable ? "Local credentials or usage files were detected." : source.setupHint]
        if let usage = providers.first(where: { $0.kind == kind }) {
            if usage.windows.isEmpty {
                details.append("No usage windows are available yet.")
            } else {
                details.append("Usage data contains \(usage.windows.count) window(s).")
            }
            if let updatedAt = usage.updatedAt {
                details.append("Last successful update: \(updatedAt.formatted(.dateTime))")
            }
            if let error = usage.error {
                details.append("Latest issue: \(error)")
            }
        } else {
            details.append("Metria has not received a response from this provider yet.")
        }
        return details.joined(separator: "\n")
    }

    public func setProviderEnabled(_ kind: ProviderKind, isEnabled: Bool) {
        var updatedKinds = enabledProviderKinds
        if isEnabled {
            updatedKinds.insert(kind)
        } else {
            updatedKinds.remove(kind)
        }
        enabledProviderKinds = updatedKinds
        defaults.set(updatedKinds.map(\.rawValue), forKey: enabledProvidersKey)
        updateVisibleProviders()
        refresh()
    }

    /// Controls whether a specific usage window (e.g. "Current session") shows up in the
    /// card, independent of `enabledProviderKinds` (which toggles a whole provider). Never
    /// lets the last visible window of a provider be hidden, so the card always has
    /// something to show.
    public func setWindowVisible(_ title: String, for kind: ProviderKind, isVisible: Bool) {
        var hiddenForKind = hiddenWindowTitlesByProvider[kind] ?? []
        if isVisible {
            hiddenForKind.remove(title)
        } else {
            let knownTitles = usageWindowTitles(for: kind)
            let visibleCount = knownTitles.filter { !hiddenForKind.contains($0) }.count
            guard visibleCount > 1 else { return }
            hiddenForKind.insert(title)
        }
        hiddenWindowTitlesByProvider[kind] = hiddenForKind
        let serializable = hiddenWindowTitlesByProvider.reduce(into: [String: [String]]()) { result, entry in
            result[entry.key.rawValue] = Array(entry.value)
        }
        defaults.set(serializable, forKey: hiddenWindowTitlesKey)
    }

    public func start() {
        refresh()
        rescheduleTimer()
    }

    /// Cancels any pending wait and starts a fresh one, so a `refreshInterval` change
    /// (e.g. from the Settings stepper) takes effect on the next tick instead of waiting
    /// out whatever was left of the previous interval.
    private func rescheduleTimer() {
        scheduleTask?.cancel()
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.refreshInterval))
                guard !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    public func refresh() {
        let providers = sources.filter {
            enabledProviderKinds.contains($0.kind) &&
            $0.isAvailable &&
            retryTasks[$0.kind] == nil
        }
        refresh(providers: providers)
    }

    private func refresh(providers: [any UsageProvider]) {
        guard !providers.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        refreshOperation = Task { [weak self] in
            // Apply each provider's result as soon as it lands instead of waiting for the
            // whole batch to finish. A provider that resolves instantly (e.g. a local-only
            // check with no session) would otherwise sit unreported — still showing its
            // last cached/optimistic state — for as long as the slowest network provider
            // in the same batch takes, which reads as a visible flicker on launch.
            await withTaskGroup(of: ProviderFetchResult.self) { group in
                for provider in providers {
                    group.addTask { await provider.fetch() }
                }
                for await result in group {
                    guard let self else { continue }
                    self.apply(result)
                    self.updateVisibleProviders()
                }
            }
            guard let self else { return }
            self.isRefreshing = false
            self.refreshOperation = nil
        }
    }

    private func apply(_ result: ProviderFetchResult) {
        let kind: ProviderKind
        switch result {
        case .loaded(let usage), .empty(let usage): kind = usage.kind
        case .failed(let failedKind, _, _): kind = failedKind
        }
        guard enabledProviderKinds.contains(kind) else {
            retryTasks[kind]?.cancel()
            retryTasks[kind] = nil
            return
        }

        switch result {
        case .loaded(let usage):
            replace(usage)
            if !usage.windows.isEmpty {
                saveCachedUsage()
            }
            if usage.error == nil {
                retryTasks[usage.kind]?.cancel()
                retryTasks[usage.kind] = nil
            }
        case .empty(let usage):
            if let index = providers.firstIndex(where: { $0.kind == usage.kind }), !providers[index].windows.isEmpty {
                providers[index].error = usage.error ?? "No current usage data was returned. Showing the last successful update."
            } else {
                replace(usage)
            }
            retryTasks[usage.kind]?.cancel()
            retryTasks[usage.kind] = nil
        case .failed(let kind, let message, let retryAfter):
            let displayMessage = retryAfter.map { "\(message) Retrying in \(Self.retryDescription($0))." } ?? message
            if let index = providers.firstIndex(where: { $0.kind == kind }) {
                providers[index].error = displayMessage
            } else {
                providers.append(ProviderUsage(kind: kind, windows: [], updatedAt: nil, error: displayMessage))
            }
            scheduleRetry(for: kind, after: retryAfter)
        }
        providers.sort { $0.kind.rawValue < $1.kind.rawValue }
    }

    private func replace(_ usage: ProviderUsage) {
        if let index = providers.firstIndex(where: { $0.kind == usage.kind }) {
            providers[index] = usage
        } else {
            providers.append(usage)
        }
    }

    private func scheduleRetry(for kind: ProviderKind, after delay: TimeInterval?) {
        guard let delay, delay > 0, retryTasks[kind] == nil,
              let provider = sources.first(where: { $0.kind == kind }) else { return }
        retryTasks[kind] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retryTasks[kind] = nil
            guard self.enabledProviderKinds.contains(kind) else { return }
            self.refresh(providers: [provider])
        }
    }

    private func saveCachedUsage() {
        let cached = providers.filter { !$0.windows.isEmpty }.map { usage in
            CachedUsage(
                kind: usage.kind.rawValue,
                windows: usage.windows.map { .init(title: $0.title, percent: $0.percent, resetDate: $0.resetDate) },
                updatedAt: usage.updatedAt
            )
        }
        guard let data = try? JSONEncoder().encode(cached) else { return }
        defaults.set(data, forKey: cachedUsageKey)
    }

    private static func loadCachedUsage(from defaults: UserDefaults, key: String) -> [ProviderUsage] {
        guard let data = defaults.data(forKey: key),
              let cached = try? JSONDecoder().decode([CachedUsage].self, from: data) else { return [] }
        return cached.compactMap { item in
            guard let kind = ProviderKind(rawValue: item.kind) else { return nil }
            return ProviderUsage(
                kind: kind,
                windows: item.windows.map { UsageWindow(title: $0.title, percent: $0.percent, resetDate: $0.resetDate) },
                updatedAt: item.updatedAt,
                error: nil
            )
        }
    }

    private static func retryDescription(_ delay: TimeInterval) -> String {
        let minutes = max(1, Int(ceil(delay / 60)))
        return minutes == 1 ? "about 1 minute" : "about \(minutes) minutes"
    }

    deinit {
        refreshOperation?.cancel()
        scheduleTask?.cancel()
        retryTasks.values.forEach { $0.cancel() }
    }
}
