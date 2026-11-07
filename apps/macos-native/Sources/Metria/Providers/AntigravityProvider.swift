import Foundation
import MetriaCore

/// Fetches Antigravity usage by shelling out to the vendor's own `agy` CLI and
/// parsing its `/usage` output.
///
/// The fresh Antigravity credential lives Keychain-only inside the CLI's own
/// entry, and this app never authorizes Keychain access, so Metria holds no
/// credential at all: the CLI authenticates itself (already authorized, no
/// prompt) and Metria only reads its tab-separated answer. Stdin is closed and
/// argv is fixed, so no user data ever reaches the subprocess.
struct AntigravityProvider: UsageProvider {
    let kind = ProviderKind.antigravity
    var isAvailable: Bool { Self.resolveBinary() != nil }
    let setupHint = String(localized: "Install Antigravity and sign in to make usage available.")
    static let fiveHourGeminiTitle = String(localized: "5-hour Gemini")
    static let weeklyGeminiTitle = String(localized: "Weekly Gemini")
    static let fiveHourArgonTitle = String(localized: "5-hour Gemini 4 Argon")
    static let weeklyArgonTitle = String(localized: "Weekly Gemini 4 Argon")
    static let fiveHourOthersTitle = String(localized: "5-hour other models")
    static let weeklyOthersTitle = String(localized: "Weekly other models")
    let usageWindowTitles = [
        fiveHourGeminiTitle, weeklyGeminiTitle,
        fiveHourArgonTitle, weeklyArgonTitle,
        fiveHourOthersTitle, weeklyOthersTitle
    ]

    /// A signed-out CLI blocks with no output (observed past 30 s), so every
    /// call carries a hard timeout that degrades to the setup hint.
    private static let timeout: TimeInterval = 30

    func fetch() async -> ProviderFetchResult {
        do {
            let output = try await runUsage()
            let windows = Self.parse(output)
            guard !windows.isEmpty else {
                return .failed(kind, setupHint, retryAfter: nil)
            }
            return .loaded(ProviderUsage(kind: kind, windows: windows, updatedAt: Date(), error: nil))
        } catch {
            return .failed(kind, setupHint, retryAfter: nil)
        }
    }

    private func runUsage() async throws -> String {
        guard let executable = Self.resolveBinary() else { throw ProviderError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let worker = DispatchQueue(label: "metria.antigravity", qos: .utility)
            let state = TimeoutState()
            worker.async {
                let process = Process()
                process.executableURL = executable
                process.arguments = ["-p", "/usage"]
                process.standardInput = FileHandle.nullDevice
                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = FileHandle.nullDevice
                // The watchdog runs on a different queue: the worker blocks in
                // waitUntilExit and could never fire a timer scheduled on itself.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.timeout) {
                    if process.isRunning { process.terminate() }
                    if state.claim() {
                        continuation.resume(throwing: ProviderError.unavailable)
                    }
                }
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    guard process.terminationStatus == 0,
                          let output = String(data: data, encoding: .utf8),
                          !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          state.claim()
                    else {
                        continuation.resume(throwing: ProviderError.unavailable)
                        return
                    }
                    continuation.resume(returning: output)
                } catch {
                    if state.claim() {
                        continuation.resume(throwing: ProviderError.unavailable)
                    }
                }
            }
        }
    }

    /// The documented installer path first, then PATH — resolved per fetch so
    /// installs and removals are picked up without a restart.
    private static func resolveBinary() -> URL? {
        let fileManager = FileManager.default
        let documented = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy")
        if fileManager.isExecutableFile(atPath: documented.path) { return documented }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        for dir in pathDirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("agy")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    enum Family: String, CaseIterable, Sendable { case gemini, argon, others }
    private enum Horizon { case fiveHour, weekly }

    /// Parses `<group>\t<window>\t<NN>%\t<ISO8601>` lines. Matching is by
    /// keyword, so minor vendor label edits degrade to fewer windows rather
    /// than zero, and a missing slot is omitted — never invented.
    static func parse(_ output: String) -> [UsageWindow] {
        var slots: [(Family, Horizon, UsageWindow)] = []
        for rawLine in output.split(separator: "\n") {
            let parts = rawLine.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 4 else { continue }
            let group = parts[0].lowercased()
            let family: Family
            if group.contains("argon") {
                family = .argon
            } else if group.contains("gemini") {
                family = .gemini
            } else {
                family = .others
            }
            let window = parts[1].lowercased()
            let horizon: Horizon
            if window.contains("five hour") || window.contains("5-hour") || window.contains("5 hour") {
                horizon = .fiveHour
            } else if window.contains("week") {
                horizon = .weekly
            } else {
                continue
            }
            guard let remaining = parsePercent(parts[2]) else { continue }
            let percent = min(max(100 - remaining, 0), 100)
            slots.append((family, horizon, UsageWindow(title: title(for: family, horizon: horizon), percent: percent, resetDate: parseDate(parts[3]))))
        }
        // Fixed card order regardless of CLI line order; first line wins a slot.
        let weeklyExhaustedFamilies: [Family: Double] = {
            var map: [Family: Double] = [:]
            for family in Family.allCases {
                if let weeklyWindow = slots.first(where: { $0.0 == family && $0.1 == .weekly })?.2,
                   weeklyWindow.percent >= 100 {
                    map[family] = weeklyWindow.percent
                }
            }
            return map
        }()

        let order: [(Family, Horizon)] = [
            (.gemini, .fiveHour), (.gemini, .weekly),
            (.argon, .fiveHour), (.argon, .weekly),
            (.others, .fiveHour), (.others, .weekly)
        ]
        return order.compactMap { slot in
            guard let rawWindow = slots.first(where: { $0.0 == slot.0 && $0.1 == slot.1 })?.2 else { return nil }
            if slot.1 == .fiveHour, let weeklyPercent = weeklyExhaustedFamilies[slot.0] {
                return UsageWindow(
                    title: rawWindow.title,
                    percent: UsageWindow.effectiveShortTermPercent(shortTerm: rawWindow.percent, longerTerm: weeklyPercent),
                    resetDate: rawWindow.resetDate,
                    usedCents: rawWindow.usedCents,
                    limitCents: rawWindow.limitCents
                )
            }
            return rawWindow
        }
    }

    private static func title(for family: Family, horizon: Horizon) -> String {
        switch (family, horizon) {
        case (.gemini, .fiveHour): fiveHourGeminiTitle
        case (.gemini, .weekly): weeklyGeminiTitle
        case (.argon, .fiveHour): fiveHourArgonTitle
        case (.argon, .weekly): weeklyArgonTitle
        case (.others, .fiveHour): fiveHourOthersTitle
        case (.others, .weekly): weeklyOthersTitle
        }
    }

    private static func parsePercent(_ raw: String) -> Double? {
        Double(raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }()
    }
}

/// One-shot guard so exactly one of the watchdog and the completion path
/// resumes the continuation.
private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

public enum AntigravityNotchFamily: String, CaseIterable, Identifiable, Sendable {
    case gemini = "gemini"
    case argon = "argon"
    case others = "others"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini: String(localized: "Gemini")
        case .argon: String(localized: "Gemini 4 Argon")
        case .others: String(localized: "Claude & GPT")
        }
    }

    public var badgeLabel: String {
        switch self {
        case .gemini: "Gemini"
        case .argon: "Argon"
        case .others: "Claude"
        }
    }

    public static let defaultsKey = "antigravityNotchFamilies"
    public static let defaultFamilies: Set<String> = Set(["gemini", "argon", "others"])

    public static func loadSelected() -> Set<String> {
        if let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) {
            let set = Set(stored)
            return set.isEmpty ? defaultFamilies : set
        }
        return defaultFamilies
    }

    public static func saveSelected(_ families: Set<String>) {
        UserDefaults.standard.set(Array(families), forKey: defaultsKey)
    }
}

extension Notification.Name {
    public static let antigravityNotchFamiliesDidChange = Notification.Name("antigravityNotchFamiliesDidChange")
}
