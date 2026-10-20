import XCTest
@testable import MetriaCore

private final class FingerprintSource: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    init(_ value: String?) { storedValue = value }
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return storedValue }
        set { lock.lock(); defer { lock.unlock() }; storedValue = newValue }
    }
}

private struct StubProvider: UsageProvider {
    let kind: ProviderKind
    let id: ProviderID
    let isAvailable: Bool
    let setupHint: String
    let usageWindowTitles: [String]
    let result: ProviderFetchResult
    var fingerprintSource: FingerprintSource? = nil

    func fetch() async -> ProviderFetchResult { result }
    var supportsAccountFingerprint: Bool { fingerprintSource != nil }
    func accountFingerprint() -> String? { fingerprintSource?.value }
}

@MainActor
final class UsageStoreContractTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MetriaCoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func stubProvider(_ kind: ProviderKind, slug: String? = nil, available: Bool = true, fingerprint: String? = nil) -> StubProvider {
        StubProvider(
            kind: kind,
            id: ProviderID(kind: kind, slug: slug),
            isAvailable: available,
            setupHint: "Set up the provider.",
            usageWindowTitles: ["Today"],
            result: .empty(ProviderUsage(kind: kind, windows: [], updatedAt: nil, error: nil)),
            fingerprintSource: fingerprint.map(FingerprintSource.init)
        )
    }

    // MARK: - SpendFormat

    func testPercentageOnlyWindowsShowPercentageForAllDisplays() {
        for display in SpendDisplay.allCases {
            let parts = SpendFormat.parts(usedCents: nil, limitCents: nil, display: display)
            XCTAssertTrue(parts.showsPercent)
            XCTAssertNil(parts.spend)
        }
    }

    func testSpendFormatCentsVisibility() {
        let percent = SpendFormat.parts(usedCents: 13000, limitCents: 25000, display: .percent)
        XCTAssertTrue(percent.showsPercent)
        XCTAssertNil(percent.spend)

        let dollars = SpendFormat.parts(usedCents: 13000, limitCents: 25000, display: .dollars)
        XCTAssertFalse(dollars.showsPercent)
        XCTAssertEqual(dollars.spend, "$130 / $250")

        let both = SpendFormat.parts(usedCents: 13000, limitCents: 25000, display: .both)
        XCTAssertTrue(both.showsPercent)
        XCTAssertEqual(both.spend, "$130 / $250")
    }

    func testSpendFormatAmountDropsWholeDollarDecimals() {
        XCTAssertEqual(SpendFormat.amount(cents: 13000), "$130")
        XCTAssertEqual(SpendFormat.amount(cents: 13050), "$130.50")
    }

    func testSpendFormatTextRequiresBothAmounts() {
        XCTAssertEqual(SpendFormat.text(usedCents: 13000, limitCents: 25000), "$130 / $250")
        XCTAssertNil(SpendFormat.text(usedCents: nil, limitCents: 25000))
        XCTAssertNil(SpendFormat.text(usedCents: 13000, limitCents: nil))
    }

    // MARK: - ProviderID

    func testProviderIDRawValueRoundTrips() {
        let codex = ProviderID(kind: .codex)
        XCTAssertEqual(codex.rawValue, "Codex")
        XCTAssertEqual(ProviderID(rawValue: codex.rawValue), codex)
        XCTAssertNil(ProviderID(rawValue: "Codex").slug)

        let claudeWork = ProviderID(kind: .claude, slug: "work")
        XCTAssertEqual(claudeWork.rawValue, "Claude-work")
        XCTAssertEqual(ProviderID(rawValue: claudeWork.rawValue), claudeWork)
        XCTAssertEqual(ProviderID(rawValue: "Claude-work").slug, "work")
    }

    // MARK: - UsageStore initialization

    func testNoSavedEnabledKeyEnablesAvailableProviders() {
        let claude = stubProvider(.claude)
        let cursor = stubProvider(.cursor)
        let unavailable = stubProvider(.codex, available: false)
        let store = UsageStore(providers: [claude, cursor, unavailable], defaults: defaults)

        XCTAssertEqual(
            store.enabledProviderIDs,
            Set([ProviderID(kind: .claude), ProviderID(kind: .cursor)])
        )
    }

    func testExplicitEmptyArrayStaysEmpty() {
        defaults.set([String](), forKey: "enabledProviderKinds")
        let providers = [stubProvider(.claude), stubProvider(.codex), stubProvider(.openCodeGo)]
        let store = UsageStore(providers: providers, defaults: defaults)

        XCTAssertTrue(store.enabledProviderIDs.isEmpty)
    }

    func testNewlyAvailableProviderIsUnionedIntoExistingSet() {
        defaults.set(["Claude", "Codex"], forKey: "knownProviderKinds")
        defaults.set(["Claude"], forKey: "enabledProviderKinds")
        let providers = [stubProvider(.claude), stubProvider(.cursor)]
        let store = UsageStore(providers: providers, defaults: defaults)

        XCTAssertEqual(
            store.enabledProviderIDs,
            Set([ProviderID(kind: .claude), ProviderID(kind: .cursor)])
        )
    }

    func testCachedUsageFromDifferentAccountIsDiscarded() {
        defaults.set(#"[{"kind":"Claude","accountFingerprint":"old-account","windows":[{"title":"Today","percent":42}],"updatedAt":814187041.0}]"#.data(using: .utf8)!, forKey: "cachedProviderUsage")
        let provider = stubProvider(.claude, fingerprint: "new-account")

        let store = UsageStore(providers: [provider], defaults: defaults)

        XCTAssertTrue(store.providers.isEmpty)
    }

    func testCachedUsageForSameAccountIsRetained() {
        defaults.set(#"[{"kind":"Claude","accountFingerprint":"same-account","windows":[{"title":"Today","percent":42}],"updatedAt":814187041.0}]"#.data(using: .utf8)!, forKey: "cachedProviderUsage")
        let provider = stubProvider(.claude, fingerprint: "same-account")

        let store = UsageStore(providers: [provider], defaults: defaults)

        XCTAssertEqual(store.providers.first?.windows.first?.percent, 42)
    }

    func testAccountSwitchClearsPreviousUsageAndRefreshesProvider() async {
        defaults.set(#"[{"kind":"Claude","accountFingerprint":"old-account","windows":[{"title":"Today","percent":42}],"updatedAt":814187041.0}]"#.data(using: .utf8)!, forKey: "cachedProviderUsage")
        let source = FingerprintSource("old-account")
        let provider = StubProvider(
            kind: .claude,
            id: ProviderID(kind: .claude),
            isAvailable: true,
            setupHint: "Set up the provider.",
            usageWindowTitles: ["Today"],
            result: .empty(ProviderUsage(kind: .claude, windows: [], updatedAt: nil, error: "No usage.")),
            fingerprintSource: source)
        let store = UsageStore(providers: [provider], defaults: defaults)
        source.value = "new-account"

        await store.checkAccountFingerprints()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(store.providers.first?.windows.isEmpty ?? false)
        XCTAssertNotEqual(store.providers.first?.windows.first?.percent, 42)
    }
}
