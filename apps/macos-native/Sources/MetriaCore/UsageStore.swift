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
        case .percent: String(localized: "Percentage")
        case .dollars: String(localized: "Dollars")
        case .both: String(localized: "Both")
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
    case antigravity = "Antigravity"

    /// The single-account providers the app has always shipped. Used so that a fresh
    /// install's first run only auto-enables what already existed before the
    /// multi-account `knownProviderIDs` migration key was introduced.
    public static let legacyKinds: Set<ProviderKind> = [.claude, .codex, .openCodeGo]

    public var id: String { rawValue }

    /// The `ProviderKind` an account-scoped raw value belongs to. A multi-account provider
    /// ids itself as `"<Kind>-<slug>"` (e.g. `"Claude-work"`), so a kind is recovered by
    /// stripping that suffix; an exact match means a single-account provider.
    public init(parsingRawValue rawValue: String) {
        if let exact = ProviderKind(rawValue: rawValue) {
            self = exact
            return
        }
        for kind in ProviderKind.allCases where rawValue.hasPrefix(kind.rawValue + "-") {
            self = kind
            return
        }
        self = .claude
    }
}

/// The identity of one provider reading, which for a multi-account provider (Claude) is a
/// single account rather than the provider as a whole.
///
/// `rawValue` doubles as the persisted key so existing single-account installs load
/// unchanged: every single-account provider's raw value equals its `ProviderKind.rawValue`
/// exactly as the older `ProviderKind` keyed store wrote it.
public struct ProviderID: Equatable, Hashable, Identifiable, Codable {
    public let kind: ProviderKind
    /// Nil for single-account providers and for the default Claude profile; the part after
    /// `Claude-` otherwise (e.g. `work`). Kept so a profile's sessions land in its own ring.
    public let slug: String?

    public var rawValue: String { slug.map { "\(kind.rawValue)-\($0)" } ?? kind.rawValue }
    public var id: String { rawValue }
    /// `Claude`, `Claude (work)`, `Codex`, … — the name shown in a card, the notch tooltip
    /// and a Settings row, so a profile is told apart from its siblings without guessing.
    public var displayName: String { slug.map { "\(kind.rawValue) (\($0))" } ?? kind.rawValue }
    /// Whether this id names the default profile of a provider (no slug) — the common case
    /// for every provider.
    public var isDefaultAccount: Bool { slug == nil }

    public init(kind: ProviderKind, slug: String? = nil) {
        self.kind = kind
        self.slug = (slug?.isEmpty == true ? nil : slug)
    }

    public init(rawValue: String) {
        let parsedKind = ProviderKind(parsingRawValue: rawValue)
        self.kind = parsedKind
        if ProviderKind(rawValue: rawValue) == nil {
            self.slug = String(rawValue.dropFirst(parsedKind.rawValue.count + 1))
        } else {
            self.slug = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AIToolsConfiguration: String, CaseIterable, Identifiable {
    case `default`
    case minimal
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .default: String(localized: "Default")
        case .minimal: String(localized: "Minimal")
        case .custom: String(localized: "Custom")
        }
    }
}

public struct ProviderUsage: Identifiable, Equatable {
    /// Which provider account these windows belong to — the key every reading is keyed by.
    public let id: ProviderID
    /// The provider family, for presentation (logo, accent colour, window titles) which is
    /// shared across that provider's accounts.
    public var kind: ProviderKind { id.kind }
    /// The name to draw in a card or row for this account (e.g. `Claude (work)`).
    public var displayName: String { id.displayName }
    /// The account's signed-in address, when the credential carries one.
    public let accountLabel: String?
    /// The account's subscription tier (e.g. "Max", "Pro", "Plus"), shown in place of the
    /// generic "Connected" badge when a provider can resolve it.
    public let planLabel: String?
    public var windows: [UsageWindow]
    public var updatedAt: Date?
    public var error: String?

    public var primary: UsageWindow? { windows.first }

    /// Account-scoped initializer, used by a multi-account provider (Claude).
    public init(id: ProviderID, accountLabel: String? = nil, planLabel: String? = nil, windows: [UsageWindow], updatedAt: Date?, error: String?) {
        self.id = id
        self.accountLabel = accountLabel
        self.planLabel = planLabel
        self.windows = windows
        self.updatedAt = updatedAt
        self.error = error
    }

    /// Single-account convenience initializer, used by every provider that has one account.
    public init(kind: ProviderKind, accountLabel: String? = nil, planLabel: String? = nil, windows: [UsageWindow], updatedAt: Date?, error: String?) {
        self.init(id: ProviderID(kind: kind), accountLabel: accountLabel, planLabel: planLabel, windows: windows, updatedAt: updatedAt, error: error)
    }
}

public enum ProviderFetchResult: Equatable {
    case loaded(ProviderUsage)
    case empty(ProviderUsage)
    case failed(ProviderID, String, retryAfter: TimeInterval?)

    /// Producer-friendly overloads so a provider can report a failure with a bare kind for
    /// its single default account. The account-scoped case (`failed(ProviderID, …)`) is the
    /// case itself.
    public static func failed(_ kind: ProviderKind, _ message: String, retryAfter: TimeInterval? = nil) -> ProviderFetchResult {
        .failed(ProviderID(kind: kind), message, retryAfter: retryAfter)
    }
}

public protocol UsageProvider {
    var kind: ProviderKind { get }
    /// The account-scoped identity of this reading. Defaults to the provider as a whole;
    /// a multi-account provider overrides it per account.
    var id: ProviderID { get }
    var isAvailable: Bool { get }
    var setupHint: String { get }
    var usageWindowTitles: [String] { get }
    func fetch() async -> ProviderFetchResult
}

public extension UsageProvider {
    var id: ProviderID { ProviderID(kind: kind) }
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
    @Published public private(set) var enabledProviderIDs: Set<ProviderID>
    @Published public private(set) var hiddenWindowTitlesByProvider: [ProviderID: Set<String>] = [:]
    @Published public private(set) var aiToolsConfiguration: AIToolsConfiguration
    /// The providers to display, in stable registration order, backfilled with an empty
    /// placeholder for any enabled account that hasn't reported usage yet. Computed once
    /// per underlying change instead of by every view that needs it on every render.
    @Published public private(set) var visibleProviders: [ProviderUsage] = []

    private let sources: [any UsageProvider]
    /// Every account a source can read, in registration order — the order Settings and the
    /// onboarding draw their rows in.
    public let registeredProviderIDs: [ProviderID]
    private let availableProviderIDs: Set<ProviderID>
    private let defaults: UserDefaults
    private var refreshOperation: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var retryTasks: [ProviderID: Task<Void, Never>] = [:]
    private var retryUntilByProvider: [ProviderID: Date]
    private var retryMessageByProvider: [ProviderID: String]
    private var isRefreshing = false
    private let enabledProvidersKey = "enabledProviderKinds"
    private let hiddenWindowTitlesKey = "hiddenUsageWindowTitles"
    private let aiToolsConfigurationKey = "aiToolsConfiguration"
    private let cachedUsageKey = "cachedProviderUsage"
    private let knownProvidersKey = "knownProviderKinds"
    private let retryUntilKey = "providerRetryUntil"
    private let retryMessagesKey = "providerRetryMessages"

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
    private static let legacyProviderKinds: Set<ProviderKind> = ProviderKind.legacyKinds

    public init(providers: [any UsageProvider], defaults: UserDefaults = .standard) {
        self.sources = providers
        self.defaults = defaults
        self.registeredProviderIDs = providers.map(\.id)
        let availableIDs = Set(providers.filter(\.isAvailable).map(\.id))
        availableProviderIDs = availableIDs

        // `nil` (key never written) means "never configured — use the minimal preset". An
        // empty array is a real, intentional choice (the user disabled every provider) and
        // must not be re-interpreted as "unconfigured" on the next launch, or a fully-disabled
        // setup would silently re-enable itself.
        let hasSavedKinds = defaults.object(forKey: enabledProvidersKey) != nil
        let savedIDs = (defaults.array(forKey: enabledProvidersKey) as? [String] ?? [])
            .map(ProviderID.init(rawValue:))
        let knownIDs = (defaults.array(forKey: knownProvidersKey) as? [String])
            .map { Set($0.map(ProviderID.init(rawValue:))) }
            ?? Set(Self.legacyProviderKinds.map { ProviderID(kind: $0) })
        let newlyAvailableIDs = availableIDs.subtracting(knownIDs)
        let initialEnabledProviderIDs = hasSavedKinds ? Set(savedIDs).union(newlyAvailableIDs) : availableIDs
        enabledProviderIDs = initialEnabledProviderIDs
        defaults.set(knownIDs.union(availableIDs).map(\.rawValue), forKey: knownProvidersKey)
        if hasSavedKinds, !newlyAvailableIDs.isEmpty {
            defaults.set((Set(savedIDs).union(newlyAvailableIDs)).map(\.rawValue), forKey: enabledProvidersKey)
        }
        let retryDates = Self.loadRetryDates(from: defaults, key: retryUntilKey)
            .filter { availableIDs.contains($0.key) && $0.value > Date() }
        self.retryUntilByProvider = retryDates
        let retryMessages = Self.loadRetryMessages(from: defaults, key: retryMessagesKey)
            .filter { retryDates[$0.key] != nil }
        self.retryMessageByProvider = retryMessages
        let cachedProviders = Self.loadCachedUsage(from: defaults, key: cachedUsageKey)
            .filter { availableIDs.contains($0.id) && initialEnabledProviderIDs.contains($0.id) }
        self.providers = cachedProviders.map { usage in
            guard let retryUntil = retryDates[usage.id] else { return usage }
            var usage = usage
            usage.error = Self.retryMessage(
                retryMessages[usage.id]
                    ?? String(localized: "The provider is temporarily unavailable for usage checks."),
                until: retryUntil
            )
            return usage
        }
        let savedHidden = (defaults.dictionary(forKey: hiddenWindowTitlesKey) as? [String: [String]]) ?? [:]
        let orderedRegisteredIDs = registeredProviderIDs
        var initialHiddenWindowTitles = savedHidden.reduce(into: [ProviderID: Set<String>]()) { result, entry in
            let id = ProviderID(rawValue: entry.key)
            guard orderedRegisteredIDs.contains(id) else { return }
            result[id] = Set(entry.value)
        }
        let initialConfiguration: AIToolsConfiguration
        if let savedConfiguration = defaults.string(forKey: aiToolsConfigurationKey)
            .flatMap(AIToolsConfiguration.init(rawValue:))
        {
            initialConfiguration = savedConfiguration
        } else if !hasSavedKinds {
            initialConfiguration = .minimal
            for provider in providers where availableIDs.contains(provider.id) {
                var titlesToHide = Set(provider.usageWindowTitles.dropFirst())
                if let cachedWindows = cachedProviders.first(where: { $0.id == provider.id })?.windows {
                    titlesToHide.formUnion(cachedWindows.dropFirst().map(\.title))
                }
                if !titlesToHide.isEmpty {
                    initialHiddenWindowTitles[provider.id] = titlesToHide
                }
            }
        } else {
            let isDefault = initialEnabledProviderIDs == availableIDs && initialHiddenWindowTitles.isEmpty
            initialConfiguration = isDefault ? .default : .custom
        }
        hiddenWindowTitlesByProvider = initialHiddenWindowTitles
        aiToolsConfiguration = initialConfiguration
        defaults.set(initialConfiguration.rawValue, forKey: aiToolsConfigurationKey)
        if !savedHidden.isEmpty || initialConfiguration == .minimal {
            let serializable = initialHiddenWindowTitles.reduce(into: [String: [String]]()) { result, entry in
                result[entry.key.rawValue] = Array(entry.value)
            }
            defaults.set(serializable, forKey: hiddenWindowTitlesKey)
        }
        updateVisibleProviders()
    }

    private func updateVisibleProviders() {
        visibleProviders = registeredProviderIDs.compactMap { id in
            guard enabledProviderIDs.contains(id),
                availableProviderIDs.contains(id),
                let usage = providers.first(where: { $0.id == id })
            else { return nil }
            return usage
        }
    }

    /// Every provider account the app can read, in Settings/onboarding order.
    public var availableProviderIDsArray: [ProviderID] {
        registeredProviderIDs.filter(availableProviderIDs.contains)
    }

    public func isProviderAvailable(_ id: ProviderID) -> Bool {
        sources.first(where: { $0.id == id })?.isAvailable ?? false
    }

    public func setupHint(for id: ProviderID) -> String? {
        sources.first(where: { $0.id == id })?.setupHint
    }

    public func usageWindowTitles(for id: ProviderID) -> [String] {
        sources.first(where: { $0.id == id })?.usageWindowTitles ?? []
    }

    public func retryDate(for id: ProviderID) -> Date? {
        guard let deadline = retryUntilByProvider[id], deadline > Date() else { return nil }
        return deadline
    }

    public var canRefresh: Bool {
        let now = Date()
        return sources.contains {
            enabledProviderIDs.contains($0.id) &&
            $0.isAvailable &&
            (retryUntilByProvider[$0.id] ?? .distantPast) <= now
        }
    }

    public func diagnosis(for id: ProviderID) -> String {
        guard let source = sources.first(where: { $0.id == id }) else {
            return String(localized: "This provider is not registered in Metria.")
        }

        var details = [source.isAvailable ? String(localized: "Local credentials or usage files were detected.") : source.setupHint]
        if let usage = providers.first(where: { $0.id == id }) {
            if usage.windows.isEmpty {
                details.append(String(localized: "No usage windows are available yet."))
            } else {
                let windowCount = usage.windows.count
                details.append(String(localized: "Usage data contains \(windowCount) window(s)."))
            }
            if let updatedAt = usage.updatedAt {
                let formattedDate = updatedAt.formatted(.dateTime)
                details.append(String(localized: "Last successful update: \(formattedDate)"))
            }
            if let error = usage.error {
                details.append(String(localized: "Latest issue: \(error)"))
            }
        } else {
            details.append(String(localized: "Metria has not received a response from this provider yet."))
        }
        return details.joined(separator: "\n")
    }

    public func setProviderEnabled(_ id: ProviderID, isEnabled: Bool) {
        var updatedIDs = enabledProviderIDs
        if isEnabled {
            updatedIDs.insert(id)
        } else {
            updatedIDs.remove(id)
            retryTasks[id]?.cancel()
            retryTasks[id] = nil
            retryUntilByProvider[id] = nil
            retryMessageByProvider[id] = nil
            saveRetryDates()
        }
        guard updatedIDs != enabledProviderIDs else { return }
        enabledProviderIDs = updatedIDs
        if isEnabled, providers.allSatisfy({ $0.id != id }) {
            providers.append(ProviderUsage(id: id, windows: [], updatedAt: nil, error: nil))
        }
        markConfigurationAsCustom()
        defaults.set(updatedIDs.map(\.rawValue), forKey: enabledProvidersKey)
        updateVisibleProviders()
        refresh()
    }

    /// Controls whether a specific usage window (e.g. "Current session") shows up in the
    /// card, independent of `enabledProviderIDs` (which toggles a whole account). Never
    /// lets the last visible window of an account be hidden, so the card always has
    /// something to show.
    public func setWindowVisible(_ title: String, for id: ProviderID, isVisible: Bool) {
        var hiddenForID = hiddenWindowTitlesByProvider[id] ?? []
        if isVisible {
            hiddenForID.remove(title)
        } else {
            let knownTitles = usageWindowTitles(for: id)
            let visibleCount = knownTitles.filter { !hiddenForID.contains($0) }.count
            guard visibleCount > 1 else { return }
            hiddenForID.insert(title)
        }
        guard hiddenForID != (hiddenWindowTitlesByProvider[id] ?? []) else { return }
        hiddenWindowTitlesByProvider[id] = hiddenForID
        let serializable = hiddenWindowTitlesByProvider.reduce(into: [String: [String]]()) { result, entry in
            result[entry.key.rawValue] = Array(entry.value)
        }
        defaults.set(serializable, forKey: hiddenWindowTitlesKey)
        markConfigurationAsCustom()
    }

    public func setAIToolsConfiguration(_ configuration: AIToolsConfiguration) {
        guard configuration != .custom else { return }

        let enabledIDs = availableProviderIDs
        var hiddenTitles: [ProviderID: Set<String>] = [:]
        if configuration == .minimal {
            for id in registeredProviderIDs where enabledIDs.contains(id) {
                let titles = usageWindowTitles(for: id)
                var titlesToHide = Set(titles.dropFirst())
                // Cached windows can carry titles localized by a previous app language.
                // Include those exact titles so stale rate-limited data follows the preset too.
                if let cachedWindows = providers.first(where: { $0.id == id })?.windows {
                    titlesToHide.formUnion(cachedWindows.dropFirst().map(\.title))
                }
                if !titlesToHide.isEmpty {
                    hiddenTitles[id] = titlesToHide
                }
            }
        }

        enabledProviderIDs = enabledIDs
        hiddenWindowTitlesByProvider = hiddenTitles
        aiToolsConfiguration = configuration
        defaults.set(enabledIDs.map(\.rawValue), forKey: enabledProvidersKey)
        let serializable = hiddenTitles.reduce(into: [String: [String]]()) { result, entry in
            result[entry.key.rawValue] = Array(entry.value)
        }
        defaults.set(serializable, forKey: hiddenWindowTitlesKey)
        defaults.set(configuration.rawValue, forKey: aiToolsConfigurationKey)
        updateVisibleProviders()
        refresh()
    }

    private func markConfigurationAsCustom() {
        guard aiToolsConfiguration != .custom else { return }
        aiToolsConfiguration = .custom
        defaults.set(aiToolsConfiguration.rawValue, forKey: aiToolsConfigurationKey)
    }

    public func start() {
        restoreRetryTasks()
        refresh(onlyStale: true)
        rescheduleTimer()
    }

    private func restoreRetryTasks() {
        let expiredIDs = retryUntilByProvider.compactMap { id, deadline in
            enabledProviderIDs.contains(id) && deadline > Date() ? nil : id
        }
        expiredIDs.forEach {
            retryUntilByProvider[$0] = nil
            retryMessageByProvider[$0] = nil
        }
        for (id, deadline) in retryUntilByProvider {
            scheduleRetry(for: id, until: deadline)
        }
        saveRetryDates()
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
                self.refresh(onlyStale: true)
            }
        }
    }

    public func refresh() {
        refresh(onlyStale: false)
    }

    private func refresh(onlyStale: Bool) {
        let now = Date()
        let providers = sources.filter {
            enabledProviderIDs.contains($0.id) &&
            $0.isAvailable &&
            retryTasks[$0.id] == nil &&
            (retryUntilByProvider[$0.id] ?? .distantPast) <= now &&
            (!onlyStale || isProviderStale($0.id, now: now))
        }
        refresh(providers: providers)
    }

    private func isProviderStale(_ id: ProviderID, now: Date) -> Bool {
        guard let updatedAt = providers.first(where: { $0.id == id })?.updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) >= refreshInterval
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
        let id: ProviderID
        switch result {
        case .loaded(let usage), .empty(let usage): id = usage.id
        case .failed(let failedID, _, _): id = failedID
        }
        guard enabledProviderIDs.contains(id) else {
            retryTasks[id]?.cancel()
            retryTasks[id] = nil
            retryUntilByProvider[id] = nil
            retryMessageByProvider[id] = nil
            saveRetryDates()
            return
        }

        switch result {
        case .loaded(let usage):
            replace(usage)
            retryUntilByProvider[usage.id] = nil
            retryMessageByProvider[usage.id] = nil
            saveRetryDates()
            if !usage.windows.isEmpty {
                saveCachedUsage()
            }
            if usage.error == nil {
                retryTasks[usage.id]?.cancel()
                retryTasks[usage.id] = nil
            }
        case .empty(let usage):
            if let index = providers.firstIndex(where: { $0.id == usage.id }), !providers[index].windows.isEmpty {
                providers[index].error = usage.error ?? String(localized: "No current usage data was returned. Showing the last successful update.")
            } else {
                replace(usage)
            }
            retryTasks[usage.id]?.cancel()
            retryTasks[usage.id] = nil
            retryUntilByProvider[usage.id] = nil
            retryMessageByProvider[usage.id] = nil
            saveRetryDates()
        case .failed(let failedID, let message, let retryAfter):
            let retryUntil = retryAfter.map { Date().addingTimeInterval($0) }
            let displayMessage = retryUntil.map { Self.retryMessage(message, until: $0) } ?? message
            if let index = providers.firstIndex(where: { $0.id == failedID }) {
                providers[index].error = displayMessage
            } else {
                providers.append(ProviderUsage(id: failedID, windows: [], updatedAt: nil, error: displayMessage))
            }
            if let retryUntil {
                retryMessageByProvider[failedID] = message
                scheduleRetry(for: failedID, until: retryUntil)
            }
        }
        providers.sort { $0.id.rawValue < $1.id.rawValue }
    }

    private func replace(_ usage: ProviderUsage) {
        if let index = providers.firstIndex(where: { $0.id == usage.id }) {
            providers[index] = usage
        } else {
            providers.append(usage)
        }
    }

    private func scheduleRetry(for id: ProviderID, until deadline: Date) {
        guard deadline > Date(), retryTasks[id] == nil,
              let provider = sources.first(where: { $0.id == id }) else { return }
        retryUntilByProvider[id] = deadline
        saveRetryDates()
        let delay = max(0, deadline.timeIntervalSinceNow)
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retryTasks[id] = nil
            guard self.enabledProviderIDs.contains(id) else { return }
            self.refresh(providers: [provider])
        }
    }

    private func saveRetryDates() {
        let dates = retryUntilByProvider.reduce(into: [String: Date]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
        guard let data = try? JSONEncoder().encode(dates) else { return }
        defaults.set(data, forKey: retryUntilKey)
        let messages = retryMessageByProvider.reduce(into: [String: String]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
        defaults.set(messages, forKey: retryMessagesKey)
    }

    private static func loadRetryDates(from defaults: UserDefaults, key: String) -> [ProviderID: Date] {
        guard let data = defaults.data(forKey: key),
              let dates = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return dates.reduce(into: [ProviderID: Date]()) { result, entry in
            result[ProviderID(rawValue: entry.key)] = entry.value
        }
    }

    private static func loadRetryMessages(from defaults: UserDefaults, key: String) -> [ProviderID: String] {
        guard let messages = defaults.dictionary(forKey: key) as? [String: String] else { return [:] }
        return messages.reduce(into: [ProviderID: String]()) { result, entry in
            result[ProviderID(rawValue: entry.key)] = entry.value
        }
    }

    private static func retryMessage(_ message: String, until deadline: Date) -> String {
        let formattedDate = deadline.formatted(date: .omitted, time: .shortened)
        return String(localized: "\(message) Metria will try again at \(formattedDate).")
    }

    private func saveCachedUsage() {
        let cached = providers.filter { !$0.windows.isEmpty }.map { usage in
            CachedUsage(
                kind: usage.id.rawValue,
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
            ProviderUsage(
                id: ProviderID(rawValue: item.kind),
                windows: item.windows.map { UsageWindow(title: $0.title, percent: $0.percent, resetDate: $0.resetDate) },
                updatedAt: item.updatedAt,
                error: nil
            )
        }
    }

    deinit {
        refreshOperation?.cancel()
        scheduleTask?.cancel()
        retryTasks.values.forEach { $0.cancel() }
    }
}
