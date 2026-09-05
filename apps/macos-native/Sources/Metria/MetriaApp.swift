import AppKit
import Combine
import CoreImage
import CryptoKit
import Foundation
import MetriaCore
import ServiceManagement
import SwiftUI

/// Stores the pairing master secret in the macOS Keychain. The secret never leaves the
/// Mac in plaintext: the PWA only ever receives it via the QR code or 12-word phrase,
/// both of which the user controls when and how to share.
enum PairingKeychain {
    private static let service = "com.metria.pairing"
    private static let account = "ntfy-pairing-secret"

    static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    @discardableResult
    static func save(_ secret: Data) -> Bool {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func loadOrGenerate() -> Data {
        if let existing = load() { return existing }
        let generated = PairingSecret.generate()
        save(generated)
        return generated
    }

    static func regenerate() -> Data {
        let generated = PairingSecret.generate()
        save(generated)
        return generated
    }
}

extension Data {
    /// URL-safe base64 without padding, so the secret can sit in a URL fragment without
    /// needing percent-encoding.
    fileprivate var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Owns the pairing secret's presentation: the QR code and the 12-word phrase shown in
/// Settings, plus the shareable link. The secret itself lives in `PairingKeychain`.
@MainActor final class PairingManager: ObservableObject {
    static let defaultRemotePWAURL = "https://metria-pwa.yuriramos2406.workers.dev"

    @Published private(set) var words: [String] = []
    @Published private(set) var qrImage: NSImage?
    private var secret: Data = Data()
    var currentSecret: Data { secret }
    /// The legacy token: the master secret itself, still accepted by `/snapshot` so
    /// deployed PWA installs keep working without a re-pair.
    var currentSnapshotToken: String { secret.base64URLEncodedString }
    /// The token new clients (the iOS app) send instead: derived from the secret, so a
    /// header captured on the LAN cannot also unlock the ntfy relay the secret protects.
    var currentLocalToken: String { PairingSecret.localToken(from: secret) }

    init() {
        secret = PairingKeychain.loadOrGenerate()
        words = PairingSecret.words(from: secret)
    }

    func regenerate() {
        secret = PairingKeychain.regenerate()
        words = PairingSecret.words(from: secret)
    }

    /// `localURL`, when the local server has a reachable address, rides along in the same
    /// QR code the PWA already reads: the PWA ignores unknown fragment parameters, so one
    /// code now pairs both clients.
    func pairingLink(pwaBaseURL: String, ntfyServer: String, localURL: String?) -> String {
        let encodedServer = ntfyServer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ntfyServer
        var link = "\(pwaBaseURL)/#s=\(secret.base64URLEncodedString)&server=\(encodedServer)"
        if let localURL, let encodedLocal = localURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            link += "&local=\(encodedLocal)"
        }
        return link
    }

    func refreshQRCode(pwaBaseURL: String, ntfyServer: String, localURL: String?) {
        qrImage = Self.renderQRCode(for: pairingLink(pwaBaseURL: pwaBaseURL, ntfyServer: ntfyServer, localURL: localURL))
    }

    private static func renderQRCode(for string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
            let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(
            cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height)
        )
    }
}

@MainActor private final class NtfyPublisher {
    private let defaults = UserDefaults.standard
    private var lastPayload: Data?
    private var publishTask: Task<Void, Never>?
    var onSnapshot: ((Data) -> Void)?

    func publish(_ providers: [ProviderUsage], secret: Data) {
        guard let server = URL(string: defaults.string(forKey: "ntfyServer") ?? "https://ntfy.sh"),
            server.scheme == "https", server.host != nil
        else { return }

        let snapshot = UsageSnapshot(
            updatedAt: Date(),
            providers: providers.compactMap { usage in
                guard let primary = usage.primary else { return nil }
                return .init(name: usage.kind.rawValue, percent: primary.percent, resetDate: primary.resetDate,
                             usedCents: primary.usedCents, limitCents: primary.limitCents)
            }
        )
        let encoder = UsageSnapshotCoding.makeEncoder()
        guard let payload = try? encoder.encode(snapshot), payload != lastPayload else { return }
        onSnapshot?(payload)

        let topic = PairingSecret.topic(from: secret)
        let key = PairingSecret.encryptionKey(from: secret)
        guard let sealed = try? AES.GCM.seal(payload, using: key), let combined = sealed.combined
        else { return }
        lastPayload = payload
        let encryptedSnapshot = combined.base64EncodedData()

        var request = URLRequest(url: server.appendingPathComponent(topic))
        request.httpMethod = "POST"
        request.httpBody = encryptedSnapshot
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue("low", forHTTPHeaderField: "Priority")
        // Superseding an in-flight publish is safe: `lastPayload` above already reflects
        // the newest snapshot, so a cancelled older request is not losing data.
        publishTask?.cancel()
        publishTask = Task {
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    deinit {
        publishTask?.cancel()
    }
}

struct MenuBarAlertSettings {
    var cautionThreshold: Int
    var warningThreshold: Int
    var criticalThreshold: Int
    var cautionColor: NSColor
    var warningColor: NSColor
    var criticalColor: NSColor

    static let `default` = Self(
        cautionThreshold: 40,
        warningThreshold: 65,
        criticalThreshold: 85,
        cautionColor: .systemYellow,
        warningColor: .systemOrange,
        criticalColor: .systemRed
    )

    static func load() -> Self {
        let defaults = UserDefaults.standard
        return Self(
            cautionThreshold: defaults.object(forKey: "menuBarCautionThreshold") as? Int ?? Self.default.cautionThreshold,
            warningThreshold: defaults.object(forKey: "menuBarWarningThreshold") as? Int ?? Self.default.warningThreshold,
            criticalThreshold: defaults.object(forKey: "menuBarCriticalThreshold") as? Int ?? Self.default.criticalThreshold,
            cautionColor: ProviderAppearance.loadColor(forKey: "menuBarCautionColor", fallback: Self.default.cautionColor),
            warningColor: ProviderAppearance.loadColor(forKey: "menuBarWarningColor", fallback: Self.default.warningColor),
            criticalColor: ProviderAppearance.loadColor(forKey: "menuBarCriticalColor", fallback: Self.default.criticalColor)
        )
    }

}

enum ProviderAppearance {
    enum Theme: String, CaseIterable, Identifiable {
        case `default`
        case custom

        var id: String { rawValue }
        var title: String {
            switch self {
            case .default: String(localized: "Default")
            case .custom: String(localized: "Custom")
            }
        }
    }

    static let themeKey = "providerColorTheme"
    private static let customColorPrefix = "providerColor."

    static var theme: Theme {
        let defaults = UserDefaults.standard
        if let rawValue = defaults.string(forKey: themeKey), let theme = Theme(rawValue: rawValue) {
            return theme
        }
        return defaults.object(forKey: "whiteProviderLogos") as? Bool == false ? .custom : .default
    }

    static func setTheme(_ theme: Theme) {
        UserDefaults.standard.set(theme.rawValue, forKey: themeKey)
        UserDefaults.standard.set(theme == .default, forKey: "whiteProviderLogos")
    }

    static func color(for kind: ProviderKind) -> NSColor {
        guard theme == .custom else { return .systemGreen }
        return loadColor(forKey: customColorKey(for: kind), fallback: defaultColor(for: kind))
    }

    static func usageColor(for kind: ProviderKind, percent: Double) -> Color {
        let settings = MenuBarAlertSettings.load()
        guard UserDefaults.standard.object(forKey: "menuBarAlertColorsEnabled") as? Bool ?? true else {
            return Color(nsColor: color(for: kind))
        }
        if percent >= Double(settings.criticalThreshold) { return Color(nsColor: settings.criticalColor) }
        if percent >= Double(settings.warningThreshold) { return Color(nsColor: settings.warningColor) }
        if percent >= Double(settings.cautionThreshold) { return Color(nsColor: settings.cautionColor) }
        return Color(nsColor: color(for: kind))
    }

    static func loadColor(forKey key: String, fallback: NSColor) -> NSColor {
        guard let data = UserDefaults.standard.data(forKey: key) else { return fallback }
        return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)) ?? fallback
    }

    static func saveColor(_ color: NSColor, for kind: ProviderKind) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: customColorKey(for: kind))
    }

    static func logo(for kind: ProviderKind) -> NSImage? {
        guard let logo = kind.logo, theme == .default else { return kind.logo }
        let tintedLogo = NSImage(size: logo.size)
        tintedLogo.lockFocus()
        logo.draw(in: NSRect(origin: .zero, size: logo.size))
        NSColor.white.set()
        NSRect(origin: .zero, size: logo.size).fill(using: .sourceAtop)
        tintedLogo.unlockFocus()
        return tintedLogo
    }

    private static func customColorKey(for kind: ProviderKind) -> String {
        "\(customColorPrefix)\(kind.rawValue)"
    }

    private static func defaultColor(for kind: ProviderKind) -> NSColor {
        switch kind {
        case .claude: .orange
        case .codex: .blue
        case .openCodeGo: .white
        case .cursor: .gray
        case .antigravity: .blue
        }
    }
}

struct ProviderLogo: View {
    let provider: ProviderKind
    let size: CGFloat
    @AppStorage(ProviderAppearance.themeKey) private var providerColorTheme = ProviderAppearance.theme.rawValue

    var body: some View {
        if let image = provider.logo {
            if (ProviderAppearance.Theme(rawValue: providerColorTheme) ?? ProviderAppearance.theme) == .default {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(.white)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
        } else {
            Image(systemName: provider.symbol)
                .font(.system(size: size * 0.7, weight: .light))
        }
    }
}

struct NotchVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct UsageCard: View {
    let usage: ProviderUsage
    var width: CGFloat = 390
    var scale: CGFloat = 1
    var showsAccount: Bool = false
    var hiddenWindowTitles: Set<String> = []
    var backgroundOpacity: Double = 1
    @AppStorage("showAccountEmails") private var showAccountEmails = true
    @AppStorage(SpendFormat.defaultsKey) private var spendDisplay = SpendDisplay.both

    private var isCompact: Bool { width < 390 }
    private var visibleWindows: [UsageWindow] {
        usage.windows.filter { !hiddenWindowTitles.contains($0.title) }
    }
    /// The progress bar's available width, mirroring this view's own horizontal padding
    /// so it no longer needs a `GeometryReader` (and the extra layout pass that comes
    /// with one) just to size itself.
    private var barWidth: CGFloat { width - 2 * (isCompact ? 14 : 24) * scale }
    var body: some View {
        VStack(alignment: .leading, spacing: (isCompact ? 10 : 18) * scale) {
            HStack(spacing: (isCompact ? 6 : 10) * scale) {
                ProviderLogo(provider: usage.kind, size: (isCompact ? 17 : 24) * scale)
                Text(usage.kind.rawValue).font(
                    .system(size: (isCompact ? 15 : 22) * scale, weight: .medium))
                if showsAccount && showAccountEmails, let accountLabel = usage.accountLabel {
                    Text(accountLabel)
                        .font(.system(size: (isCompact ? 10 : 13) * scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if usage.error == nil, let planLabel = usage.planLabel {
                    Text(planLabel)
                        .font(.system(size: (isCompact ? 9 : 12) * scale, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, (isCompact ? 5 : 7) * scale)
                        .padding(.vertical, (isCompact ? 2 : 3) * scale)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                } else {
                    Circle().fill(usage.error == nil ? .green : .orange).frame(
                        width: (isCompact ? 5 : 7) * scale, height: (isCompact ? 5 : 7) * scale)
                }
            }
            if usage.windows.isEmpty {
                Label(
                    usage.error ?? "Waiting for usage data...",
                    systemImage: usage.error == nil ? "clock" : "exclamationmark.triangle.fill"
                )
                .font(.system(size: (isCompact ? 10 : 13) * scale))
                .foregroundStyle(usage.error == nil ? Color.secondary : Color.orange)
                .lineLimit(3)
            } else if visibleWindows.isEmpty {
                Label(
                    "All usage windows for \(usage.kind.rawValue) are hidden. Enable one in Settings.",
                    systemImage: "eye.slash"
                )
                .font(.system(size: (isCompact ? 10 : 13) * scale))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            } else {
                ForEach(Array(visibleWindows.enumerated()), id: \.element.id) { index, window in
                    VStack(alignment: .leading, spacing: (isCompact ? 5 : 8) * scale) {
                        HStack { Text(window.localizedTitle(for: usage.kind, index: index)); Spacer(); Text(window.resetText).foregroundStyle(.secondary) }.font(.system(size: (isCompact ? 10 : 15) * scale))
                        ZStack(alignment: .leading) { Capsule().fill(Color(white: 0.10)); Capsule().fill(ProviderAppearance.usageColor(for: usage.kind, percent: window.percent)).frame(width: max(0, barWidth * window.percent / 100)) }.frame(height: (isCompact ? 5 : 7) * scale)
                        let parts = window.spendParts(spendDisplay)
                        HStack(spacing: (isCompact ? 6 : 10) * scale) {
                            if parts.showsPercent { Text("\(Int(window.percent.rounded()))% Used") }
                            if let spend = parts.spend {
                                Spacer(minLength: 0)
                                Text(spend).monospacedDigit()
                            }
                        }.font(.system(size: (isCompact ? 11 : 15) * scale))
                    }
                }
            }
            if let error = usage.error {
                Text(error).font(.system(size: (isCompact ? 9 : 12) * scale)).foregroundStyle(
                    .secondary
                ).lineLimit(2)
            }
        }.padding(.horizontal, (isCompact ? 14 : 24) * scale).padding(
            .vertical, (isCompact ? 16 : 28) * scale
        ).frame(width: width).background(Color.black.opacity(backgroundOpacity)).clipShape(
            RoundedRectangle(cornerRadius: (isCompact ? 16 : 24) * scale)
        ).foregroundStyle(.white)
    }
}

extension UsageWindow {
    func localizedTitle(for provider: ProviderKind, index: Int) -> String {
        let titles: [String]
        switch provider {
        case .claude:
            titles = [ClaudeProvider.fiveHourLimitTitle, ClaudeProvider.weeklyLimitTitle]
        case .codex:
            titles = [CodexProvider.fiveHourLimitTitle, CodexProvider.weeklyLimitTitle]
        case .openCodeGo:
            titles = [OpenCodeGoProvider.fiveHourLimitTitle, OpenCodeGoProvider.weeklyLimitTitle, OpenCodeGoProvider.monthlyLimitTitle]
        case .cursor:
            titles = [CursorProvider.cursorModelsTitle, CursorProvider.apiUsageTitle]
        case .antigravity:
            titles = [AntigravityProvider.fiveHourGeminiTitle, AntigravityProvider.weeklyGeminiTitle, AntigravityProvider.fiveHourOthersTitle, AntigravityProvider.weeklyOthersTitle]
        }
        return titles.indices.contains(index) ? titles[index] : title
    }

    var resetText: String {
        guard let resetDate else { return String(localized: "No reset data") }
        let seconds = resetDate.timeIntervalSinceNow

        if seconds > 0 && seconds < 86400 {
            let totalMinutes = Int(seconds / 60)
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60

            if hours > 0 {
                return minutes > 0
                    ? String(localized: "Resets in \(hours) hr \(minutes) min") : String(localized: "Resets in \(hours) hr")
            }

            return String(localized: "Resets in \(minutes) min")
        }

        let formattedDate = resetDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return String(localized: "Resets \(formattedDate)")
    }
}

struct DashboardUsageCard: View {
    let usage: ProviderUsage
    let showsAccount: Bool
    var hiddenWindowTitles: Set<String> = []
    var alertSettings: MenuBarAlertSettings = .default
    @AppStorage("showAccountEmails") private var showAccountEmails = true
    @AppStorage(SpendFormat.defaultsKey) private var spendDisplay = SpendDisplay.both

    private var visibleWindows: [UsageWindow] {
        usage.windows.filter { !hiddenWindowTitles.contains($0.title) }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if usage.windows.isEmpty {
                    Label(
                        usage.error ?? "Waiting for usage data...",
                        systemImage: usage.error == nil ? "clock" : "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(usage.error == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                } else if visibleWindows.isEmpty {
                    Label(
                        "All usage windows for \(usage.kind.rawValue) are hidden. Enable one in Settings.",
                        systemImage: "eye.slash"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(visibleWindows.enumerated()), id: \.element.id) { index, window in
                        let color = ProviderAppearance.usageColor(for: usage.kind, percent: window.percent)
                        let parts = window.spendParts(spendDisplay)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(window.localizedTitle(for: usage.kind, index: index))
                                Spacer()
                                if parts.showsPercent {
                                    Text("\(Int(window.percent.rounded()))%")
                                        .foregroundStyle(color)
                                        .monospacedDigit()
                                } else if let spend = parts.spend {
                                    Text(spend)
                                        .foregroundStyle(color)
                                        .monospacedDigit()
                                }
                            }
                            .font(.subheadline)
                            ProgressView(value: min(max(window.percent, 0), 100), total: 100)
                                .tint(color)
                            HStack {
                                Text(window.resetText)
                                Spacer()
                                if parts.showsPercent, let spend = parts.spend {
                                    Text(spend).monospacedDigit()
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = usage.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
        } label: {
            HStack(spacing: 8) {
                ProviderLogo(provider: usage.kind, size: 20)
                Text(usage.kind.rawValue)
                if showsAccount && showAccountEmails, let accountLabel = usage.accountLabel {
                    Text(accountLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if usage.error == nil, let planLabel = usage.planLabel {
                    Text(planLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .help("\(usage.kind.rawValue) plan")
                } else if usage.error == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Connected")
                        .help("Connected")
                }
            }
        }
        .padding(16)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct PopoverContent: View {
    @ObservedObject var store: UsageStore
    let alertSettings: MenuBarAlertSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dashboard").font(.title2.weight(.semibold))
                    Text("AI coding assistant usage").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: store.refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.visibleProviders.isEmpty {
                        Label(
                            "No providers are available yet. Sign in to a supported provider and refresh.",
                            systemImage: "externaldrive.badge.questionmark"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(store.visibleProviders) {
                            DashboardUsageCard(
                                usage: $0, showsAccount: true,
                                hiddenWindowTitles: store.hiddenWindowTitlesByProvider[$0.kind]
                                    ?? [],
                                alertSettings: alertSettings)
                        }
                    }
                }
            }

            Divider()

            Text("Updated \(Date().formatted(.dateTime.hour().minute()))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 440, height: 700)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

/// The notch grows either as a vertical pill (left/right, single-corner anchored) or a
/// horizontal bar (top/bottom, centered and growing symmetrically like a Dynamic Island).
enum NotchAxis {
    case vertical
    case horizontal
}

/// Which screen edge the notch is anchored to.
enum NotchPosition: String, CaseIterable, Identifiable {
    case top
    case left
    case right
    case bottom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .top: String(localized: "Top")
        case .left: String(localized: "Left")
        case .right: String(localized: "Right")
        case .bottom: String(localized: "Bottom")
        }
    }
    var axis: NotchAxis { self == .top || self == .bottom ? .horizontal : .vertical }

    /// The corner(s) touching the screen edge stay square; the opposite, exposed corner(s)
    /// are rounded — mirroring the shape's flush side to whichever edge this position anchors to.
    func cornerRadii(_ radius: CGFloat) -> RectangleCornerRadii {
        switch self {
        case .right:
            RectangleCornerRadii(
                topLeading: radius, bottomLeading: radius, bottomTrailing: 0, topTrailing: 0)
        case .left:
            RectangleCornerRadii(
                topLeading: 0, bottomLeading: 0, bottomTrailing: radius, topTrailing: radius)
        case .top:
            RectangleCornerRadii(
                topLeading: 0, bottomLeading: radius, bottomTrailing: radius, topTrailing: 0)
        case .bottom:
            RectangleCornerRadii(
                topLeading: radius, bottomLeading: 0, bottomTrailing: 0, topTrailing: radius)
        }
    }

    var zStackAlignment: Alignment {
        switch self {
        case .right: .trailing
        case .left: .leading
        case .top: .top
        case .bottom: .bottom
        }
    }

    var hiddenHintSymbolName: String {
        switch self {
        case .right: "chevron.left"
        case .left: "chevron.right"
        case .top: "chevron.down"
        case .bottom: "chevron.up"
        }
    }

    var symbolName: String {
        switch self {
        case .top: "chevron.up"
        case .left: "chevron.left"
        case .right: "chevron.right"
        case .bottom: "chevron.down"
        }
    }
}

/// Gives the screen-edge side a small vertical overhang while keeping the exposed side
/// at the original height.
struct NotchShape: Shape {
    let position: NotchPosition
    let radius: CGFloat
    let squareSideExtension: CGFloat

    func path(in rect: CGRect) -> Path {
        let extensionAmount =
            position.axis == .vertical
            ? min(squareSideExtension, rect.height / 3)
            : min(squareSideExtension, rect.width / 3)
        let cornerRadius = min(radius, rect.width / 2, rect.height / 2)
        let roundedTop = extensionAmount + cornerRadius
        let roundedBottom = rect.height - extensionAmount - cornerRadius
        var path = Path()

        switch position {
        case .right:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addCurve(
                to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY + extensionAmount),
                control1: CGPoint(x: rect.maxX, y: rect.minY + extensionAmount * 0.65),
                control2: CGPoint(
                    x: rect.minX + cornerRadius * 1.35, y: rect.minY + extensionAmount)
            )
            path.addCurve(
                to: CGPoint(x: rect.minX, y: roundedTop),
                control1: CGPoint(
                    x: rect.minX + cornerRadius * 0.45, y: rect.minY + extensionAmount),
                control2: CGPoint(
                    x: rect.minX, y: rect.minY + extensionAmount + cornerRadius * 0.45)
            )
            path.addLine(to: CGPoint(x: rect.minX, y: roundedBottom))
            path.addCurve(
                to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - extensionAmount),
                control1: CGPoint(
                    x: rect.minX, y: rect.maxY - extensionAmount - cornerRadius * 0.45),
                control2: CGPoint(
                    x: rect.minX + cornerRadius * 0.45, y: rect.maxY - extensionAmount)
            )
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY),
                control1: CGPoint(
                    x: rect.minX + cornerRadius * 1.35, y: rect.maxY - extensionAmount),
                control2: CGPoint(x: rect.maxX, y: rect.maxY - extensionAmount * 0.65)
            )
        case .left:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addCurve(
                to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY + extensionAmount),
                control1: CGPoint(x: rect.minX, y: rect.minY + extensionAmount * 0.65),
                control2: CGPoint(
                    x: rect.maxX - cornerRadius * 1.35, y: rect.minY + extensionAmount)
            )
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: roundedTop),
                control1: CGPoint(
                    x: rect.maxX - cornerRadius * 0.45, y: rect.minY + extensionAmount),
                control2: CGPoint(
                    x: rect.maxX, y: rect.minY + extensionAmount + cornerRadius * 0.45)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: roundedBottom))
            path.addCurve(
                to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - extensionAmount),
                control1: CGPoint(
                    x: rect.maxX, y: rect.maxY - extensionAmount - cornerRadius * 0.45),
                control2: CGPoint(
                    x: rect.maxX - cornerRadius * 0.45, y: rect.maxY - extensionAmount)
            )
            path.addCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY),
                control1: CGPoint(
                    x: rect.maxX - cornerRadius * 0.85, y: rect.maxY - extensionAmount),
                control2: CGPoint(x: rect.minX, y: rect.maxY - extensionAmount * 0.65)
            )
        case .top:
            let verticalPath = NotchShape(
                position: .right,
                radius: radius,
                squareSideExtension: squareSideExtension
            ).path(in: CGRect(x: 0, y: 0, width: rect.height, height: rect.width))
            return verticalPath.applying(
                CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: rect.height)
            )
        case .bottom:
            let verticalPath = NotchShape(
                position: .right,
                radius: radius,
                squareSideExtension: squareSideExtension
            ).path(in: CGRect(x: 0, y: 0, width: rect.height, height: rect.width))
            return verticalPath.applying(
                CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: rect.width, ty: 0)
            )
        }

        path.closeSubpath()
        return path
    }
}

/// Resolves where the notch sits for a given `NotchPosition`: flush against the chosen
/// screen edge, using `visibleFrame` rather than the physical notch's `safeAreaInsets`
/// (a screen edge isn't hardware) so it stays clear of the menu bar's icons and, on
/// notched Macs, the real notch.
struct NotchGeometry {
    private let position: NotchPosition
    private let leftEdgeX: CGFloat
    private let rightEdgeX: CGFloat
    private let topEdgeY: CGFloat
    private let bottomEdgeY: CGFloat
    private let centerX: CGFloat

    static func current(for screen: NSScreen? = nil, position: NotchPosition = .right)
        -> NotchGeometry
    {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return NotchGeometry(
                position: position, leftEdgeX: 0, rightEdgeX: 0, topEdgeY: 0, bottomEdgeY: 0,
                centerX: 0)
        }
        // The left/right pill keeps a small gap so it doesn't crowd the menu bar's icons;
        // the top/bottom bar has no such icons to clear, so it sits flush against the edge.
        let edgeInset: CGFloat = position.axis == .horizontal ? 0 : 12
        return NotchGeometry(
            position: position,
            leftEdgeX: screen.frame.minX,
            rightEdgeX: screen.frame.maxX,
            topEdgeY: screen.visibleFrame.maxY - edgeInset,
            bottomEdgeY: screen.visibleFrame.minY + edgeInset,
            centerX: screen.frame.midX
        )
    }

    /// `thickness` is the surface's fixed cross-axis size (the pill's width for left/right,
    /// the bar's height for top/bottom); `extent` is the size along the growth axis (height
    /// for left/right, width for top/bottom); `alongEdgeOffset` is the user-draggable offset
    /// along the anchor edge (vertical for left/right, horizontal for top/bottom) — used to
    /// compute the expanded shelf's frame too, so it grows from the idle rail without jumping.
    func frame(thickness: CGFloat, extent: CGFloat, alongEdgeOffset: CGFloat = 0) -> CGRect {
        switch position {
        case .right:
            CGRect(
                x: rightEdgeX - thickness, y: topEdgeY - extent + alongEdgeOffset, width: thickness,
                height: extent)
        case .left:
            CGRect(
                x: leftEdgeX, y: topEdgeY - extent + alongEdgeOffset, width: thickness,
                height: extent)
        case .top:
            CGRect(
                x: centerX - extent / 2 + alongEdgeOffset, y: topEdgeY - thickness, width: extent,
                height: thickness)
        case .bottom:
            CGRect(
                x: centerX - extent / 2 + alongEdgeOffset, y: bottomEdgeY, width: extent,
                height: thickness)
        }
    }
}

enum NotchSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Default")
        case .large: String(localized: "Large")
        }
    }
    var symbolName: String {
        switch self {
        case .small: "textformat.size.smaller"
        case .medium: "textformat.size"
        case .large: "textformat.size.larger"
        }
    }
    var scale: CGFloat {
        switch self {
        case .small: 0.85
        case .medium: 1
        case .large: 1.15
        }
    }
}

struct NotchMetrics {
    let scale: CGFloat
    let providerCount: Int

    init(size: NotchSize, providerCount: Int = ProviderKind.allCases.count) {
        scale = size.scale
        self.providerCount = max(providerCount, 1)
    }

    var idleWidth: CGFloat { 80 * scale }
    /// Sized to fit the visible providers stacked in `compactProviders`, so the rail never
    /// overflows its own fixed-height container.
    var compactHeight: CGFloat {
        let count = CGFloat(providerCount)
        return count * providerItemHeight + max(count - 1, 0) * providerSpacing + 24 * scale
    }
    var railExtent: CGFloat { compactHeight + squareSideExtension * 2 }
    var hoverHeight: CGFloat {
        railExtent + (controlsHeight + controlsGap + controlsBottomSpace) * 2
    }
    var hiddenWidth: CGFloat { 18 * scale }
    var hiddenHeight: CGFloat { 80 * scale }
    var cornerRadius: CGFloat { 40 * scale }
    var squareSideExtension: CGFloat { 40 * scale }
    var providerItemHeight: CGFloat { 64 * scale }
    var providerSpacing: CGFloat { 10 * scale }
    var cardSpacing: CGFloat { 12 * scale }
    var cardWidth: CGFloat { 316 * scale }
    var cardContentWidth: CGFloat { 300 * scale }
    var controlsSpacing: CGFloat { 14 * scale }
    var controlsHeight: CGFloat { 24 * scale }
    var controlsGap: CGFloat { 0 }
    var controlsBottomSpace: CGFloat { 0 }
    var interactionMargin: CGFloat { 8 * scale }

    /// Maps a (thickness, extent) pair — thickness being the fixed cross-axis size, extent
    /// the size along the growth axis — onto an actual (width, height), swapped for a
    /// horizontal bar so the same numeric constants produce either orientation.
    func size(thickness: CGFloat, extent: CGFloat, axis: NotchAxis) -> CGSize {
        axis == .vertical
            ? CGSize(width: thickness, height: extent) : CGSize(width: extent, height: thickness)
    }
}

/// Shared visibility state so the view and the window-level click routing stay in sync
/// without relying on SwiftUI `Button` actions, which are unreliable in a non-activating
/// borderless panel.
@MainActor final class NotchMode: ObservableObject {
    @Published var isHiddenMode = UserDefaults.standard.bool(forKey: "hiddenNotch")
    @Published var isOpeningSettings = false
    @Published var size =
        NotchSize(rawValue: UserDefaults.standard.string(forKey: "notchSize") ?? "") ?? .medium
    @Published var position =
        NotchPosition(rawValue: UserDefaults.standard.string(forKey: "notchPosition") ?? "")
        ?? .right
}

/// The floating surface itself: a compact provider rail — a vertical pill flush against
/// the left/right screen edge, or a horizontal bar flush against the top/bottom edge —
/// which grows on hover into a shelf revealing the hide/pin and settings controls at its
/// two ends. All states share the same flush-edge, rounded-opposite-edge silhouette so the
/// surface reads as attached to the screen rather than as a floating rectangle.
struct NotchContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var mode: NotchMode
    let backgroundOpacity: Double
    let onNotchHover: (Bool) -> Void
    let onProviderHover: (ProviderKind, Int, Bool) -> Void
    let onProviderTap: (ProviderKind) -> Void
    @State private var isHovered = false
    @State private var hasAppeared = false
    @State private var pendingHoverCollapse: DispatchWorkItem?

    private var isHiddenMode: Bool { mode.isHiddenMode }
    private var metrics: NotchMetrics {
        NotchMetrics(size: mode.size, providerCount: store.visibleProviders.count)
    }
    private var position: NotchPosition { mode.position }
    private var axis: NotchAxis { position.axis }

    private var currentSize: CGSize {
        let size = metrics.size(
            thickness: isHiddenMode && !isHovered ? metrics.hiddenWidth : metrics.idleWidth,
            extent: isHiddenMode && !isHovered
                ? metrics.hiddenHeight : isHovered ? metrics.hoverHeight : metrics.railExtent,
            axis: axis
        )
        return size
    }
    private var maxSize: CGSize {
        let size = metrics.size(
            thickness: metrics.idleWidth, extent: metrics.hoverHeight, axis: axis)
        return size
    }
    private var trackingSize: CGSize {
        let extent =
            (isHiddenMode && !isHovered
                ? metrics.hiddenHeight : isHovered ? metrics.hoverHeight : metrics.railExtent)
            + metrics.interactionMargin * 2
        return metrics.size(
            thickness: isHiddenMode && !isHovered ? metrics.hiddenWidth : metrics.idleWidth,
            extent: extent,
            axis: axis)
    }
    private var maxTrackingSize: CGSize {
        metrics.size(
            thickness: metrics.idleWidth,
            extent: metrics.hoverHeight + metrics.interactionMargin * 2,
            axis: axis)
    }
    private var hiddenPeekSize: CGSize {
        metrics.size(thickness: metrics.hiddenWidth, extent: metrics.hiddenHeight, axis: axis)
    }
    private var endControlSize: CGSize {
        metrics.size(thickness: metrics.idleWidth, extent: metrics.controlsHeight, axis: axis)
    }

    private var appearOffset: CGSize {
        guard !hasAppeared else { return .zero }
        let delta = 18 * metrics.scale
        switch position {
        case .right: return CGSize(width: delta, height: 0)
        case .left: return CGSize(width: -delta, height: 0)
        case .top: return CGSize(width: 0, height: -delta)
        case .bottom: return CGSize(width: 0, height: delta)
        }
    }

    var body: some View {
        ZStack(alignment: position.zStackAlignment) {
            NotchVisualEffect()
                .opacity(backgroundOpacity)
                .frame(
                    width: currentSize.width, height: currentSize.height,
                    alignment: position.zStackAlignment
                )
                .clipShape(
                    NotchShape(
                        position: position,
                        radius: metrics.cornerRadius,
                        squareSideExtension: metrics.squareSideExtension
                    )
                )
                .overlay {
                    NotchShape(
                        position: position,
                        radius: metrics.cornerRadius,
                        squareSideExtension: metrics.squareSideExtension
                    )
                    .fill(.black.opacity(0.72 * backgroundOpacity))
                }
            /*
             The native visual effect view is required here because the notch is
             hosted in an AppKit panel outside the normal SwiftUI window hierarchy.
             */
            NotchShape(
                position: position,
                radius: metrics.cornerRadius,
                squareSideExtension: metrics.squareSideExtension
            )
            .fill(.black.opacity(backgroundOpacity))
            .frame(
                width: currentSize.width, height: currentSize.height,
                alignment: position.zStackAlignment
            )
            .overlay {
                NotchShape(
                    position: position,
                    radius: metrics.cornerRadius,
                    squareSideExtension: metrics.squareSideExtension
                )
                .stroke(.white.opacity(0.14), lineWidth: 1)
            }
            if !isHiddenMode || isHovered {
                compactProviders
                    .frame(
                        width: axis == .vertical ? metrics.idleWidth : nil,
                        height: axis == .horizontal ? metrics.idleWidth : nil,
                        alignment: position.zStackAlignment
                    )
            }
            if isHiddenMode && !isHovered {
                Image(systemName: position.hiddenHintSymbolName)
                    .font(.system(size: 11 * metrics.scale, weight: .semibold))
                    .foregroundStyle(Color(white: 0.58))
                    .frame(width: hiddenPeekSize.width, height: hiddenPeekSize.height)
                    .accessibilityLabel("Hover to open notch")
                    .help("Hover to open notch")
            }

            if isHovered {
                endControls
            }
        }
        .frame(
            width: currentSize.width, height: currentSize.height,
            alignment: position.zStackAlignment
        )
        .contentShape(
            NotchShape(
                position: position,
                radius: metrics.cornerRadius,
                squareSideExtension: metrics.squareSideExtension
            )
        )
        // Track a small invisible margin around the active surface. It prevents the shelf
        // from collapsing while the cursor moves between the rail and an end control.
        .frame(
            width: trackingSize.width,
            height: trackingSize.height,
            alignment: position.zStackAlignment)
        .onHover { isInside in
            pendingHoverCollapse?.cancel()
            if isInside {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                    isHovered = true
                }
                onNotchHover(true)
            } else {
                let collapse = DispatchWorkItem {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                        isHovered = false
                    }
                    onNotchHover(false)
                }
                pendingHoverCollapse = collapse
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: collapse)
            }
        }
        .frame(
            width: maxTrackingSize.width,
            height: maxTrackingSize.height,
            alignment: position.zStackAlignment)
        .opacity(hasAppeared ? 1 : 0)
        .offset(appearOffset)
        .onAppear {
            withAnimation(.easeOut(duration: 0.32).delay(0.15)) {
                hasAppeared = true
            }
        }
        // The rail is always a dark, near-black surface by design, independent of the
        // system appearance; force Dark Mode's color resolution so any adaptive color
        // used here (now or later) reads correctly against it.
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var compactProviders: some View {
        if axis == .vertical {
            VStack(spacing: 0) { providerRows }.padding(.vertical, 12 * metrics.scale)
        } else {
            HStack(spacing: 0) { providerRows }.padding(.horizontal, 12 * metrics.scale)
        }
    }

    private var providerRows: some View {
        ForEach(Array(store.visibleProviders.enumerated()), id: \.element.id) { index, usage in
            let rowExtent =
                metrics.providerItemHeight
                + (index < store.visibleProviders.count - 1 ? metrics.providerSpacing : 0)
            let itemSize = metrics.size(
                thickness: metrics.idleWidth, extent: metrics.providerItemHeight, axis: axis)
            let rowSize = metrics.size(thickness: metrics.idleWidth, extent: rowExtent, axis: axis)
            SidebarProviderItem(
                usage: usage, scale: metrics.scale
            )
            .frame(width: itemSize.width, height: itemSize.height)
            .frame(width: rowSize.width, height: rowSize.height)
            .contentShape(Rectangle())
            .help(usage.kind.rawValue)
            .onHover { isHovering in
                onProviderHover(usage.kind, index, isHovering)
            }
            .onTapGesture {
                onProviderTap(usage.kind)
            }
        }
    }

    /// Vertical positions reveal the two controls above/below the compact rail using the
    /// existing corner-anchored offset trick; horizontal positions pin them to the bar's
    /// leading/trailing edge instead, since the bar itself grows symmetrically from center.
    @ViewBuilder private var endControls: some View {
        if axis == .vertical {
            topControls
                .frame(width: endControlSize.width, height: endControlSize.height)
                .offset(
                    y:
                        -(metrics.railExtent / 2 + metrics.controlsGap + metrics.controlsHeight
                        / 2)
                )
                .transition(.opacity)
            bottomControls
                .frame(width: endControlSize.width, height: endControlSize.height)
                .offset(
                    y: metrics.railExtent / 2 + metrics.controlsGap + metrics.controlsHeight / 2
                )
                .transition(.opacity)
        } else {
            topControls
                .frame(width: endControlSize.width, height: endControlSize.height)
                .padding(.leading, metrics.controlsBottomSpace)
                .frame(width: maxSize.width, height: maxSize.height, alignment: .leading)
                .transition(.opacity)
            bottomControls
                .frame(width: endControlSize.width, height: endControlSize.height)
                .padding(.trailing, metrics.controlsBottomSpace)
                .frame(width: maxSize.width, height: maxSize.height, alignment: .trailing)
                .transition(.opacity)
        }
    }

    private var topControls: some View {
        Image(systemName: isHiddenMode ? "pin.fill" : "eye.slash")
            .font(.system(size: 11 * metrics.scale))
            .foregroundStyle(Color(white: 0.58))
            .frame(width: 24 * metrics.scale, height: 24 * metrics.scale)
            .background(Circle().fill(Color.black))
            .accessibilityLabel(isHiddenMode ? "Pin notch" : "Hide notch")
            .help(isHiddenMode ? "Pin notch" : "Hide notch")
            .frame(maxWidth: .infinity)
            .frame(height: metrics.controlsHeight)
            .onHover { isInside in
                (isInside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
    }

    private var bottomControls: some View {
        HStack(spacing: metrics.controlsSpacing) {
            Spacer()
            Group {
                if mode.isOpeningSettings {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Opening settings")
                        .help("Opening settings")
                } else {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11 * metrics.scale))
                        .foregroundStyle(Color(white: 0.58))
                        .help("Settings")
                }
            }
            .frame(width: 24 * metrics.scale, height: 24 * metrics.scale)
            .background(Circle().fill(Color.black))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: metrics.controlsHeight)
        .onHover { isInside in
            (isInside ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }
}

struct NotchCardContent: View {
    let usage: ProviderUsage
    let hiddenWindowTitles: Set<String>
    let metrics: NotchMetrics
    let position: NotchPosition
    let backgroundOpacity: Double
    let onHover: (Bool) -> Void

    /// The pointer shape always points from "right", so it only needs rotating to face
    /// back into whichever edge the rail is anchored to.
    private var pointerRotation: Angle {
        switch position {
        case .right: .degrees(0)
        case .left: .degrees(180)
        case .top: .degrees(-90)
        case .bottom: .degrees(90)
        }
    }

    /// `UsageCard` (not the popover's `DashboardUsageCard`/`GroupBox`) so the whole card —
    /// fonts, padding, corner radius — scales with the notch size setting instead of only
    /// its outer frame, and its background/corners come from this view alone, with no
    /// separate stroked overlay on top.
    private var card: some View {
        UsageCard(
            usage: usage,
            width: metrics.cardContentWidth,
            scale: metrics.scale,
            showsAccount: true,
            hiddenWindowTitles: hiddenWindowTitles,
            backgroundOpacity: backgroundOpacity
        )
        // Keyed by provider so swapping the hovered provider while the card is already on
        // screen crossfades/scales between the two cards instead of hard-cutting the content,
        // matching the `withAnimation` the host applies when it reassigns `rootView`.
        .id(usage.kind)
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .center)))
    }

    private var pointer: some View {
        let rotated = position.axis == .horizontal
        return SideNotchPointer()
            .fill(.black.opacity(backgroundOpacity))
            .frame(width: 16 * metrics.scale, height: 34 * metrics.scale)
            .rotationEffect(pointerRotation)
            .frame(
                width: rotated ? 34 * metrics.scale : 16 * metrics.scale,
                height: rotated ? 16 * metrics.scale : 34 * metrics.scale)
    }

    var body: some View {
        Group {
            switch position {
            case .right:
                HStack(spacing: 0) {
                    card
                    pointer
                }
            case .left:
                HStack(spacing: 0) {
                    pointer
                    card
                }
            case .top:
                VStack(spacing: 0) {
                    pointer
                    card
                }
            case .bottom:
                VStack(spacing: 0) {
                    card
                    pointer
                }
            }
        }
        .onHover(perform: onHover)
        // This card always sits on a near-black surface regardless of the system
        // appearance, but DashboardUsageCard's text uses adaptive colors (.primary,
        // .secondary) that otherwise resolve dark in Light Mode, making them nearly
        // invisible here. Force Dark Mode's color resolution to match the fixed backdrop.
        .preferredColorScheme(.dark)
    }
}

struct SideNotchPointer: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// Captures taps on the two bottom controls directly at the window level, since SwiftUI
/// `Button` actions can be dropped in a non-activating borderless panel. Also captures
/// vertical drags before child SwiftUI views can consume them.
final class DraggableNotchPanel: NSPanel {
    var metrics = NotchMetrics(size: .medium)
    var position: NotchPosition = .right
    var onDragMove: ((CGFloat) -> Void)?
    var onGearTap: ((NSPoint) -> Void)?
    var onEyeTap: (() -> Void)?
    var onContextMenu: ((NSPoint) -> Void)?
    private var lastMouseScreenPoint: NSPoint?
    private var didDrag = false
    private var didHandleControlTap = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            didDrag = false
            didHandleControlTap = routeControlTap(at: event.locationInWindow)
            if didHandleControlTap {
                lastMouseScreenPoint = nil
                return
            }
            lastMouseScreenPoint = convertPoint(toScreen: event.locationInWindow)
        case .leftMouseDragged:
            guard !didHandleControlTap else { return }
            didDrag = true
            if let lastMouseScreenPoint {
                let currentMouseScreenPoint = convertPoint(toScreen: event.locationInWindow)
                let delta =
                    position.axis == .vertical
                    ? currentMouseScreenPoint.y - lastMouseScreenPoint.y
                    : currentMouseScreenPoint.x - lastMouseScreenPoint.x
                onDragMove?(delta)
                self.lastMouseScreenPoint = currentMouseScreenPoint
            }
            return
        case .leftMouseUp:
            if didHandleControlTap {
                didHandleControlTap = false
                lastMouseScreenPoint = nil
                return
            }
            if !didDrag { _ = routeControlTap(at: event.locationInWindow) }
            didHandleControlTap = false
            lastMouseScreenPoint = nil
        case .rightMouseDown:
            onContextMenu?(event.locationInWindow)
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    // The two control bands mirror the SwiftUI layout around the provider rail: centered
    // above/below it for a vertical pill (`maxExtent / 2` is the rail's fixed center, since
    // the window reserves symmetric space around it), at its leading/trailing ends for a
    // horizontal bar.
    @discardableResult
    private func routeControlTap(at point: NSPoint) -> Bool {
        let endExtent = metrics.controlsHeight
        let maxExtent = metrics.hoverHeight
        let interactionMargin = metrics.interactionMargin

        switch position.axis {
        case .vertical:
            let half = maxExtent / 2
            let leadingBandBottom =
                interactionMargin + half + metrics.railExtent / 2 + metrics.controlsGap
            let leadingBandTop = leadingBandBottom + endExtent
            if point.y >= leadingBandBottom && point.y <= leadingBandTop {
                onEyeTap?()
                return true
            }

            let trailingBandTop =
                interactionMargin + half - metrics.railExtent / 2 - metrics.controlsGap
            let trailingBandBottom = trailingBandTop - endExtent
            if point.y >= trailingBandBottom && point.y <= trailingBandTop {
                onGearTap?(point)
                return true
            }
        case .horizontal:
            let leadingBandStart = interactionMargin + metrics.controlsBottomSpace
            let leadingBandEnd = leadingBandStart + endExtent
            if point.x >= leadingBandStart && point.x <= leadingBandEnd {
                onEyeTap?()
                return true
            }

            let trailingBandEnd =
                interactionMargin + maxExtent - metrics.controlsBottomSpace
            let trailingBandStart = trailingBandEnd - endExtent
            if point.x >= trailingBandStart && point.x <= trailingBandEnd {
                onGearTap?(point)
                return true
            }
        }

        return false
    }
}

/// Keeps the rail's rounded corners transparent to the rest of the menu bar.
final class NotchHostingView: NSHostingView<NotchContent> {
    var isHovered = false
    var isHiddenMode = false
    var metrics = NotchMetrics(size: .medium)
    var position: NotchPosition = .right

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsVisibleSurface(point) else { return nil }
        return super.hitTest(point)
    }

    /// The surface rect, in a left-based/top-based frame matching `bounds`: the thickness
    /// axis always hugs the flush screen edge (single-sided); the extent axis hugs the top
    /// for a vertical pill (single-sided) or centers for a horizontal bar (double-sided,
    /// mirroring `NotchGeometry`'s centered anchoring for top/bottom).
    private func surfaceFrame(width: CGFloat, height: CGFloat) -> CGRect {
        switch position {
        case .right: CGRect(x: bounds.width - width, y: 0, width: width, height: height)
        case .left: CGRect(x: 0, y: 0, width: width, height: height)
        case .top: CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: height)
        case .bottom:
            CGRect(
                x: (bounds.width - width) / 2, y: bounds.height - height, width: width,
                height: height)
        }
    }

    /// Whether the corner at the given quadrant (in the same left-based/top-based frame) is
    /// one of the two rounded corners for this position — mirrors `NotchPosition.cornerRadii`.
    private func isCornerRounded(left: Bool, top: Bool) -> Bool {
        switch position {
        case .right: left
        case .left: !left
        case .top: !top
        case .bottom: top
        }
    }

    private func containsVisibleSurface(_ point: NSPoint) -> Bool {
        let topBasedY = isFlipped ? point.y : bounds.height - point.y
        let thickness = isHiddenMode && !isHovered ? metrics.hiddenWidth : metrics.idleWidth
        let extent =
            isHiddenMode && !isHovered
            ? metrics.hiddenHeight
            : isHovered ? metrics.hoverHeight : metrics.compactHeight
        let interactionExtent = extent + metrics.interactionMargin * 2
        let size = metrics.size(thickness: thickness, extent: interactionExtent, axis: position.axis)
        let rect = surfaceFrame(width: size.width, height: size.height)
        let testPoint = CGPoint(x: point.x, y: topBasedY)

        guard rect.contains(testPoint) else { return false }

        let radius = min(metrics.cornerRadius, rect.width / 2, rect.height / 2)
        let inSafeBand =
            (testPoint.x >= rect.minX + radius && testPoint.x <= rect.maxX - radius)
            || (testPoint.y >= rect.minY + radius && testPoint.y <= rect.maxY - radius)
        guard !inSafeBand else { return true }

        let isLeft = testPoint.x < rect.midX
        let isTop = testPoint.y < rect.midY
        guard isCornerRounded(left: isLeft, top: isTop) else { return true }

        let cornerCenter = CGPoint(
            x: isLeft ? rect.minX + radius : rect.maxX - radius,
            y: isTop ? rect.minY + radius : rect.maxY - radius)
        let distanceX = testPoint.x - cornerCenter.x
        let distanceY = testPoint.y - cornerCenter.y
        return distanceX * distanceX + distanceY * distanceY <= radius * radius
    }
}

struct AnimatedPercentageText: View, Animatable {
    var percent: Double
    let scale: CGFloat

    var animatableData: Double {
        get { percent }
        set { percent = newValue }
    }

    var body: some View {
        Text("\(Int(percent.rounded()))%")
            .font(.system(size: 11 * scale, weight: .regular, design: .rounded))
            .foregroundStyle(.white)
    }
}

struct SidebarProviderItem: View {
    let usage: ProviderUsage
    let scale: CGFloat
    @State private var displayedPercent = 0.0

    private var percent: Double { usage.primary?.percent ?? 0 }
    private var progressColor: Color {
        ProviderAppearance.usageColor(for: usage.kind, percent: percent)
    }

    var body: some View {
        VStack(spacing: 3 * scale) {
            ZStack {
                Circle().stroke(Color(white: 0.10), lineWidth: 5 * scale)
                Circle().trim(from: 0, to: displayedPercent / 100)
                    .stroke(
                        progressColor, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                ProviderLogo(provider: usage.kind, size: 14 * scale).foregroundStyle(.white)
            }
            .frame(width: 38 * scale, height: 38 * scale)
            AnimatedPercentageText(percent: displayedPercent, scale: scale)
        }
        .contentShape(Rectangle())
        .onAppear { animatePercent(to: percent, delay: 0.15) }
        .onChange(of: percent) { newPercent in animatePercent(to: newPercent) }
    }

    private func animatePercent(to percent: Double, delay: Double = 0) {
        withAnimation(.easeOut(duration: 1.2).delay(delay)) {
            displayedPercent = percent
        }
    }
}

struct NotchScreen: Identifiable, Hashable {
    let id: UInt32
    let name: String
}

enum NotchBehavior: String, CaseIterable, Identifiable {
    case pinned
    case autoHide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: String(localized: "Pinned")
        case .autoHide: String(localized: "Auto-hide")
        }
    }

    var symbolName: String {
        switch self {
        case .pinned: "pin.fill"
        case .autoHide: "eye.slash"
        }
    }
}

enum LaunchAtLoginManager {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) -> String? {
        guard isAvailable else {
            return String(localized: "Launch at login is available after installing Metria as an app in Applications.")
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let reason = error.localizedDescription
            return String(localized: "Metria could not update its launch-at-login setting: \(reason)")
        }

        if enabled, SMAppService.mainApp.status == .requiresApproval {
            return String(localized: "Metria was added, but macOS requires approval. Open System Settings > General > Login Items and allow Metria.")
        }
        return nil
    }
}

/// The UI language Metria launches with. "System" clears the override entirely, so the app
/// follows whatever language macOS itself uses. Foundation only reads `AppleLanguages` at
/// process launch, so a change here only takes effect after a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case portugueseBrazil = "pt-BR"

    var id: String { rawValue }

    /// Language names are shown in their own language (an endonym), matching how macOS's
    /// own language picker presents them — not translated into the current UI language.
    var displayName: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .portugueseBrazil: "Português (Brasil)"
        }
    }
}

enum AppLanguageManager {
    private static let key = "AppleLanguages"

    static var current: AppLanguage {
        guard let saved = UserDefaults.standard.array(forKey: key) as? [String],
              let code = saved.first else { return .system }
        return AppLanguage(rawValue: code) ?? .system
    }

    static func setLanguage(_ language: AppLanguage) {
        switch language {
        case .system:
            UserDefaults.standard.removeObject(forKey: key)
        default:
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }

    /// Relaunches Metria as a fresh process so the new `AppleLanguages` override takes
    /// effect; a no-op (returns `false`) outside a packaged .app, e.g. `swift run`.
    @discardableResult
    static func relaunch() -> Bool {
        guard LaunchAtLoginManager.isAvailable else { return false }
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case design
    case providers
    case iPhone

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .design: String(localized: "Design")
        case .providers: String(localized: "AI Tools")
        case .iPhone: String(localized: "Phone")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .design: "paintpalette"
        case .providers: "square.stack.3d.up"
        case .iPhone: "iphone"
        }
    }
}

private struct SettingsLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Opening Settings…")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 680, minHeight: 500)
    }
}

/// A segmented-style picker where every option genuinely fills an equal share of the row.
/// `Picker(...).pickerStyle(.segmented)` on macOS keeps its native control at its intrinsic
/// (fit) size and centers it even inside a `.frame(maxWidth: .infinity)`, leaving dead space
/// on both sides instead of stretching each segment.
/// A real `NSSegmentedControl` wrapper with `segmentDistribution = .fillEqually`, so the
/// segments genuinely stretch to fill the row while keeping native press/hover states,
/// keyboard navigation and accessibility — a pure-SwiftUI reimplementation can't match that.
private struct FlexSegmentedControl<Option: Hashable>: NSViewRepresentable {
    let options: [Option]
    let title: (Option) -> String
    var symbolName: ((Option) -> String)? = nil
    @Binding var selection: Option

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: options.map(title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.font = NSFont.systemFont(ofSize: 11)
        control.segmentDistribution = .fillEqually
        if let symbolName {
            for (index, option) in options.enumerated() {
                guard let image = NSImage(
                    systemSymbolName: symbolName(option), accessibilityDescription: nil
                ) else { continue }
                let configuredImage = image.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
                ) ?? image
                control.setImage(configuredImage, forSegment: index)
                control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            }
        }
        control.selectedSegment = options.firstIndex(of: selection) ?? 0
        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        let index = options.firstIndex(of: selection) ?? 0
        if nsView.selectedSegment != index {
            nsView.selectedSegment = index
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: FlexSegmentedControl
        init(parent: FlexSegmentedControl) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard parent.options.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.options[sender.selectedSegment]
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var pairing: PairingManager
    @AppStorage("showAccountEmails") private var showAccountEmails = true
    @AppStorage(SpendFormat.defaultsKey) private var spendDisplay = SpendDisplay.both
    @AppStorage(ProviderAppearance.themeKey) private var providerColorTheme = ProviderAppearance.theme.rawValue
    @State private var showsNotch: Bool
    let onToggleNotch: (Bool) -> Void
    @State private var showsMenuBar: Bool
    let onToggleMenuBar: (Bool) -> Void
    let notchScreens: [NotchScreen]
    let notchScreenID: UInt32
    let onSelectNotchScreen: (UInt32) -> Void
    @State private var notchBehavior: NotchBehavior
    let onSelectNotchBehavior: (NotchBehavior) -> Void
    @State private var notchSize: NotchSize
    let onSelectNotchSize: (NotchSize) -> Void
    @State private var notchPosition: NotchPosition
    let onSelectNotchPosition: (NotchPosition) -> Void
    @State private var providerColors: [ProviderKind: Color]
    let onChangeProviderAppearance: () -> Void
    @State private var menuBarAlertColorsEnabled: Bool
    let onChangeMenuBarAlertColors: (Bool) -> Void
    @AppStorage("showMenuBarProviderNames") private var showMenuBarProviderNames = true
    let onChangeMenuBarProviderNames: (Bool) -> Void
    @State private var cautionThreshold: Int
    @State private var warningThreshold: Int
    @State private var criticalThreshold: Int
    @State private var cautionColor: Color
    @State private var warningColor: Color
    @State private var criticalColor: Color
    let onChangeMenuBarAlertSettings: (MenuBarAlertSettings) -> Void
    @State private var sidebarOpacity: Double
    let onChangeSidebarOpacity: (Double) -> Void
    @State private var launchAtLoginEnabled: Bool
    let onChangeLaunchAtLogin: (Bool) -> String?
    let onQuit: () -> Void
    let onReconnect: (ProviderKind) -> Void
    @State private var ntfyServer: String
    let onChangeServer: (String) -> Void
    let localPWAURL: () -> String?
    let localServerURL: () -> String?
    @State private var localServerPort: String
    let onChangeLocalServerPort: (UInt16) -> Void
    @State private var customPWAURL: String
    let onChangeCustomPWAURL: (String) -> Void
    let onRegeneratePairing: () -> Void
    let canCheckForUpdates: Bool
    let onCheckForUpdates: () -> Void
    @State private var isPhraseRevealed = false
    @State private var isRegenerateConfirmationShown = false
    @State private var isDiagnosticShown = false
    @State private var diagnosticMessage = ""
    @State private var isReconnectShown = false
    @State private var reconnectMessage = ""
    @State private var launchAtLoginMessage: String?
    @State private var selectedLanguage: AppLanguage = AppLanguageManager.current
    @State private var isLanguageRestartPromptShown = false
    @State private var selectedSection: SettingsSection = .general
    @State private var expandedProviderKinds: Set<ProviderKind> = []

    init(
        store: UsageStore,
        pairing: PairingManager,
        showsNotch: Bool,
        onToggleNotch: @escaping (Bool) -> Void,
        showsMenuBar: Bool,
        onToggleMenuBar: @escaping (Bool) -> Void,
        notchScreens: [NotchScreen],
        notchScreenID: UInt32,
        onSelectNotchScreen: @escaping (UInt32) -> Void,
        notchBehavior: NotchBehavior,
        onSelectNotchBehavior: @escaping (NotchBehavior) -> Void,
        notchSize: NotchSize,
        onSelectNotchSize: @escaping (NotchSize) -> Void,
        notchPosition: NotchPosition,
        onSelectNotchPosition: @escaping (NotchPosition) -> Void,
        providerColors: [ProviderKind: NSColor],
        onChangeProviderAppearance: @escaping () -> Void,
        menuBarAlertColorsEnabled: Bool,
        onChangeMenuBarAlertColors: @escaping (Bool) -> Void,
        onChangeMenuBarProviderNames: @escaping (Bool) -> Void,
        menuBarAlertSettings: MenuBarAlertSettings,
        onChangeMenuBarAlertSettings: @escaping (MenuBarAlertSettings) -> Void,
        sidebarOpacity: Double,
        onChangeSidebarOpacity: @escaping (Double) -> Void,
        launchAtLoginEnabled: Bool,
        onChangeLaunchAtLogin: @escaping (Bool) -> String?,
        onQuit: @escaping () -> Void,
        onReconnect: @escaping (ProviderKind) -> Void,
        ntfyServer: String,
        onChangeServer: @escaping (String) -> Void,
        localPWAURL: @escaping () -> String?,
        localServerURL: @escaping () -> String?,
        localServerPort: UInt16,
        onChangeLocalServerPort: @escaping (UInt16) -> Void,
        customPWAURL: String,
        onChangeCustomPWAURL: @escaping (String) -> Void,
        onRegeneratePairing: @escaping () -> Void,
        canCheckForUpdates: Bool,
        onCheckForUpdates: @escaping () -> Void
    ) {
        self.store = store
        self.pairing = pairing
        _showsNotch = State(initialValue: showsNotch)
        self.onToggleNotch = onToggleNotch
        _showsMenuBar = State(initialValue: showsMenuBar)
        self.onToggleMenuBar = onToggleMenuBar
        self.notchScreens = notchScreens
        self.notchScreenID = notchScreenID
        self.onSelectNotchScreen = onSelectNotchScreen
        _notchBehavior = State(initialValue: notchBehavior)
        self.onSelectNotchBehavior = onSelectNotchBehavior
        _notchSize = State(initialValue: notchSize)
        self.onSelectNotchSize = onSelectNotchSize
        _notchPosition = State(initialValue: notchPosition)
        self.onSelectNotchPosition = onSelectNotchPosition
        _providerColors = State(initialValue: providerColors.mapValues { Color(nsColor: $0) })
        self.onChangeProviderAppearance = onChangeProviderAppearance
        _menuBarAlertColorsEnabled = State(initialValue: menuBarAlertColorsEnabled)
        self.onChangeMenuBarAlertColors = onChangeMenuBarAlertColors
        self.onChangeMenuBarProviderNames = onChangeMenuBarProviderNames
        _cautionThreshold = State(initialValue: menuBarAlertSettings.cautionThreshold)
        _warningThreshold = State(initialValue: menuBarAlertSettings.warningThreshold)
        _criticalThreshold = State(initialValue: menuBarAlertSettings.criticalThreshold)
        _cautionColor = State(initialValue: Color(nsColor: menuBarAlertSettings.cautionColor))
        _warningColor = State(initialValue: Color(nsColor: menuBarAlertSettings.warningColor))
        _criticalColor = State(initialValue: Color(nsColor: menuBarAlertSettings.criticalColor))
        self.onChangeMenuBarAlertSettings = onChangeMenuBarAlertSettings
        _sidebarOpacity = State(initialValue: sidebarOpacity)
        self.onChangeSidebarOpacity = onChangeSidebarOpacity
        _launchAtLoginEnabled = State(initialValue: launchAtLoginEnabled)
        self.onChangeLaunchAtLogin = onChangeLaunchAtLogin
        self.onQuit = onQuit
        self.onReconnect = onReconnect
        _ntfyServer = State(initialValue: ntfyServer)
        self.onChangeServer = onChangeServer
        self.localPWAURL = localPWAURL
        self.localServerURL = localServerURL
        _localServerPort = State(initialValue: String(localServerPort))
        self.onChangeLocalServerPort = onChangeLocalServerPort
        _customPWAURL = State(initialValue: customPWAURL)
        self.onChangeCustomPWAURL = onChangeCustomPWAURL
        self.onRegeneratePairing = onRegeneratePairing
        self.canCheckForUpdates = canCheckForUpdates
        self.onCheckForUpdates = onCheckForUpdates
    }

    private static let mascotImage: NSImage? = {
        guard
            let url = MetriaResources.bundle.url(forResource: "metria-mascot", withExtension: "png")
        else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        navigationContent
            .frame(minWidth: 680, idealWidth: 720, minHeight: 500, idealHeight: 580)
    }

    private var navigationContent: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if let mascot = SettingsView.mascotImage {
                        Image(nsImage: mascot)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    }
                    Text("Metria")
                        .font(.headline)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                List(SettingsSection.allCases, selection: $selectedSection) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
                .listStyle(.sidebar)

                Divider()
                Button(role: .destructive, action: onQuit) {
                    Label("Quit", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .frame(minWidth: 140, idealWidth: 150, maxWidth: 170)

            VStack(alignment: .leading, spacing: 0) {
                Text(selectedSection.title)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                Divider()
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var detailView: some View {
        switch selectedSection {
        case .general: generalView
        case .design: designView
        case .providers: providersView
        case .iPhone: phoneView
        }
    }

    private var generalView: some View {
        VStack(spacing: 0) {
            Form {
            Section {
                Stepper(value: $store.refreshInterval, in: 60...1800, step: 60) {
                    Text("Refresh every \(Int(store.refreshInterval / 60)) min")
                }
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: { enabled in
                            if let message = onChangeLaunchAtLogin(enabled) {
                                launchAtLoginMessage = message
                            } else {
                                launchAtLoginEnabled = enabled
                            }
                        }
                    ))
            } header: {
                Label("Behavior", systemImage: "gearshape")
            }

            Section {
                Picker("Language", selection: $selectedLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .onChange(of: selectedLanguage) { newLanguage in
                    AppLanguageManager.setLanguage(newLanguage)
                    isLanguageRestartPromptShown = true
                }
            } header: {
                Label("Language", systemImage: "globe")
            }

            Section {
                Text("Metria")
                    .font(.headline)
                HStack {
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        Text("Version \(version)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link(destination: URL(string: "https://github.com/yurirxmos/metria")!) {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Button("Check for Updates…", action: onCheckForUpdates)
                    .disabled(!canCheckForUpdates)
                if !canCheckForUpdates {
                    Text("Automatic updates aren't configured for this build.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("About", systemImage: "info.circle")
            }
            }
            .formStyle(.grouped)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        }
        .alert(
            "Launch at login",
            isPresented: Binding(
                get: { launchAtLoginMessage != nil },
                set: { if !$0 { launchAtLoginMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { launchAtLoginMessage = nil }
        } message: {
            Text(launchAtLoginMessage ?? "")
        }
        .alert("Restart Required", isPresented: $isLanguageRestartPromptShown) {
            Button("Later", role: .cancel) {}
            Button("Restart Now") {
                guard AppLanguageManager.relaunch() else { return }
            }
        } message: {
            Text("Restart Metria to apply the new language.")
        }
    }

    private var designView: some View {
        Form {
            Section {
                Toggle(
                    "Show notch",
                    isOn: Binding(
                        get: { showsNotch },
                        set: { newValue in
                            showsNotch = newValue
                            onToggleNotch(newValue)
                        }
                    )
                )
                .disabled(showsNotch && !showsMenuBar)
                Toggle(
                    "Show in menu bar",
                    isOn: Binding(
                        get: { showsMenuBar },
                        set: { newValue in
                            showsMenuBar = newValue
                            onToggleMenuBar(newValue)
                        }
                    )
                )
                .disabled(showsMenuBar && !showsNotch)
                Toggle("Show provider account email", isOn: $showAccountEmails)
                Picker("Show usage as", selection: $spendDisplay) {
                    ForEach(SpendDisplay.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } header: {
                Label("Display", systemImage: "rectangle.on.rectangle")
            }

            Section {
                LabeledContent("Behavior") {
                    FlexSegmentedControl(
                        options: NotchBehavior.allCases,
                        title: { $0.title },
                        symbolName: { $0.symbolName },
                        selection: Binding(
                            get: { notchBehavior },
                            set: { newValue in
                                notchBehavior = newValue
                                onSelectNotchBehavior(newValue)
                            }
                        )
                    )
                    .frame(minHeight: 24)
                }
                Picker(
                    "Monitor", selection: Binding(get: { notchScreenID }, set: onSelectNotchScreen)
                ) {
                    ForEach(notchScreens) { screen in
                        Text(screen.name).tag(screen.id)
                    }
                }

                LabeledContent("Position") {
                    FlexSegmentedControl(
                        options: NotchPosition.allCases,
                        title: { $0.title },
                        symbolName: { $0.symbolName },
                        selection: Binding(
                            get: { notchPosition },
                            set: { newValue in
                                notchPosition = newValue
                                onSelectNotchPosition(newValue)
                            }
                        )
                    )
                    .frame(minHeight: 24)
                }
                LabeledContent("Size") {
                    FlexSegmentedControl(
                        options: NotchSize.allCases,
                        title: { $0.title },
                        symbolName: { $0.symbolName },
                        selection: Binding(
                            get: { notchSize },
                            set: { newValue in
                                notchSize = newValue
                                onSelectNotchSize(newValue)
                            }
                        )
                    )
                    .frame(minHeight: 24)
                }
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: $sidebarOpacity, in: 0.35...1)
                            .onChange(of: sidebarOpacity) { onChangeSidebarOpacity($0) }
                        Text("\(Int(sidebarOpacity * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            } header: {
                Label("Notch", systemImage: "rectangle.portrait.and.arrow.right")
            }

            Section {
                Toggle("Color usage alerts", isOn: $menuBarAlertColorsEnabled)
                    .onChange(of: menuBarAlertColorsEnabled) { onChangeMenuBarAlertColors($0) }
                menuBarAlertControls
                    .disabled(!menuBarAlertColorsEnabled)
            } header: {
                Label("Usage colors", systemImage: "paintpalette")
            }

            Section {
                Toggle("Show provider names", isOn: $showMenuBarProviderNames)
                    .onChange(of: showMenuBarProviderNames) { onChangeMenuBarProviderNames($0) }
            } header: {
                Label("Menu bar", systemImage: "menubar.rectangle")
            }

        }
        .formStyle(.grouped)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var menuBarAlertControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            alertControl(
                label: String(localized: "Caution"), color: $cautionColor, threshold: $cautionThreshold,
                range: 1...(warningThreshold - 1))
            alertControl(
                label: String(localized: "Warning"), color: $warningColor, threshold: $warningThreshold,
                range: (cautionThreshold + 1)...(criticalThreshold - 1))
            alertControl(
                label: String(localized: "Critical"), color: $criticalColor, threshold: $criticalThreshold,
                range: (warningThreshold + 1)...100)
        }
    }

    private func providerColorBinding(for kind: ProviderKind) -> Binding<Color> {
        Binding(
            get: { providerColors[kind] ?? Color(nsColor: ProviderAppearance.color(for: kind)) },
            set: { color in
                providerColors[kind] = color
                ProviderAppearance.saveColor(NSColor(color), for: kind)
                onChangeProviderAppearance()
            }
        )
    }

    private func alertControl(
        label: String, color: Binding<Color>, threshold: Binding<Int>, range: ClosedRange<Int>
    ) -> some View {
        GridRow {
            Text(label)
            ColorPicker("\(label) color", selection: color)
                .labelsHidden()
                .onChange(of: color.wrappedValue) { _ in saveMenuBarAlertSettings() }
            Stepper("\(threshold.wrappedValue)%", value: threshold, in: range)
                .onChange(of: threshold.wrappedValue) { _ in saveMenuBarAlertSettings() }
                .frame(width: 92)
        }
    }

    private func saveMenuBarAlertSettings() {
        onChangeMenuBarAlertSettings(
            .init(
                cautionThreshold: cautionThreshold,
                warningThreshold: warningThreshold,
                criticalThreshold: criticalThreshold,
                cautionColor: NSColor(cautionColor),
                warningColor: NSColor(warningColor),
                criticalColor: NSColor(criticalColor)
            ))
    }

    /// A small colored status dot shown right after the provider name: green when connected
    /// (available and enabled), red when it isn't connected at all, orange-gray when available
    /// but turned off.
    private func providerStatusDot(for kind: ProviderKind) -> some View {
        let color: Color
        if !store.isProviderAvailable(kind) {
            color = .red
        } else if store.enabledProviderKinds.contains(kind) {
            color = .green
        } else {
            color = .gray
        }
        return Circle()
            .fill(color)
            .frame(width: 9, height: 9)
    }

    /// The dismissable header row of a provider: logo, name, a short status right after the
    /// name, and the disclosure chevron pushed to the trailing edge. The entire row is a
    /// button so clicking anywhere on it toggles the provider's settings.
    private func providerRowHeader(for kind: ProviderKind) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                if expandedProviderKinds.contains(kind) {
                    expandedProviderKinds.remove(kind)
                } else {
                    expandedProviderKinds.insert(kind)
                }
            }
        } label: {
            HStack(spacing: 12) {
                ProviderLogo(provider: kind, size: 18)
                Text(kind.rawValue)
                providerStatusDot(for: kind)
                Spacer()
                Image(systemName: expandedProviderKinds.contains(kind) ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .buttonStyle(.plain)
    }

    private func providerDetail(for kind: ProviderKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "Use this provider",
                isOn: Binding(
                    get: { store.enabledProviderKinds.contains(kind) },
                    set: { store.setProviderEnabled(kind, isEnabled: $0) }
                )
            )
            .disabled(!store.isProviderAvailable(kind))

            ForEach(store.usageWindowTitles(for: kind), id: \.self) { title in
                Toggle(
                    "Show \"\(title)\"",
                    isOn: Binding(
                        get: {
                            !(store.hiddenWindowTitlesByProvider[kind]?.contains(title) ?? false)
                        },
                        set: { store.setWindowVisible(title, for: kind, isVisible: $0) }
                    ))
            }

            HStack {
                Button("Diagnose") {
                    diagnosticMessage = store.diagnosis(for: kind)
                    isDiagnosticShown = true
                }
                Button("Reconnect") {
                    onReconnect(kind)
                    let providerName = kind.rawValue
                    let command = kind.reconnectCommand
                    reconnectMessage =
                        String(localized: "The login command for \(providerName) was sent to Terminal. If it did not start automatically, paste this command:\n\n\(command)")
                    isReconnectShown = true
                }
                Spacer()
            }
            .controlSize(.small)

            if let usage = store.providers.first(where: { $0.kind == kind }), let error = usage.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(4)
            }
            if let usage = store.providers.first(where: { $0.kind == kind }), let updatedAt = usage.updatedAt {
                Text("Last update: \(updatedAt.formatted(.dateTime.hour().minute()))")
                    .foregroundStyle(.secondary)
            }

            if !store.isProviderAvailable(kind), let hint = store.setupHint(for: kind) {
                Text(hint).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var providersView: some View {
        Form {
            Section {
                FlexSegmentedControl(
                    options: AIToolsConfiguration.allCases,
                    title: { $0.title },
                    selection: Binding(
                        get: { store.aiToolsConfiguration },
                        set: { store.setAIToolsConfiguration($0) }
                    )
                )
                .frame(maxWidth: .infinity, minHeight: 24)
            } header: {
                Label("Mode", systemImage: "slider.horizontal.3")
            }
            Section {
                ForEach(ProviderKind.allCases) { kind in
                    providerRow(for: kind)
                }
            } header: {
                Label("Providers", systemImage: "square.stack.3d.up")
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Provider diagnosis", isPresented: $isDiagnosticShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticMessage)
        }
        .alert("Reconnect provider", isPresented: $isReconnectShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reconnectMessage)
        }
    }

    /// One provider's collapsible block inside the grouped form: the full-width header row
    /// plus, when expanded, its settings details.
    private func providerRow(for kind: ProviderKind) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            providerRowHeader(for: kind)
            if expandedProviderKinds.contains(kind) {
                providerDetail(for: kind)
            }
        }
        .padding(.vertical, 6)
    }

    private var phoneView: some View {
        Form {
            Section {
                if let qrImage = pairing.qrImage {
                    HStack {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 132, height: 132)
                        Spacer()
                    }
                }

                HStack {
                    Text(
                        isPhraseRevealed
                            ? pairing.words.joined(separator: " ")
                            : String(repeating: "•", count: 44)
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(isPhraseRevealed ? "Hide" : "Show") { isPhraseRevealed.toggle() }
                }

                HStack(spacing: 10) {
                    Button("Copy phrase") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            pairing.words.joined(separator: " "), forType: .string)
                    }
                    Button("Copy link") {
                        guard let pwaBaseURL = localPWAURL() else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pairing.pairingLink(pwaBaseURL: pwaBaseURL, ntfyServer: ntfyServer, localURL: localServerURL()), forType: .string)
                    }
                    Spacer()
                    Button("Regenerate", role: .destructive) {
                        isRegenerateConfirmationShown = true
                    }
                }
                .controlSize(.small)
            } header: {
                Label("Pair your phone", systemImage: "iphone")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ntfy server")
                        .font(.headline)
                    TextField("https://ntfy.sh", text: $ntfyServer)
                        .onSubmit { onChangeServer(ntfyServer) }
                }
            } header: {
                Label("Connection", systemImage: "network")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local address")
                        .font(.headline)
                    Text(localPWAURL() ?? String(localized: "Starting local server…"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local server port")
                        .font(.headline)
                    TextField("", text: $localServerPort)
                        .onSubmit {
                            guard let port = UInt16(localServerPort), port > 0 else { return }
                            onChangeLocalServerPort(port)
                        }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom PWA URL")
                        .font(.headline)
                    TextField("", text: $customPWAURL)
                        .onSubmit { onChangeCustomPWAURL(customPWAURL) }
                }
            } header: {
                Label("PWA hosting", systemImage: "server.rack")
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Regenerate pairing?", isPresented: $isRegenerateConfirmationShown) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) {
                onRegeneratePairing()
            }
        } message: {
            Text("Any phone using the current QR code or phrase will stop receiving updates.")
        }
    }
}

extension NSMenu {
    @discardableResult
    fileprivate func addItem(
        withTitle title: String, action: Selector?, keyEquivalent: String, symbolName: String
    ) -> NSMenuItem {
        let item = addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent)
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        return item
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = UsageStore(providers: ProviderRegistry.makeProviders())
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var sidebarWindow: NSPanel!
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?
    var observation: AnyCancellable?
    var visibleProvidersObservation: AnyCancellable?
    var enabledProvidersObservation: AnyCancellable?
    var hiddenWindowsObservation: AnyCancellable?
    private let ntfyPublisher = NtfyPublisher()
    let pairing = PairingManager()
    private let updater = AppUpdater()
    private let localPWAServer = LocalPWAServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateDisplayModeIfNeeded()
        NSApp.setActivationPolicy(.accessory)
        store.start()
        configureStatusItem()
        configurePopover()
        configureSidebar()
        localPWAServer.setSnapshotTokens([pairing.currentSnapshotToken, pairing.currentLocalToken])
        ntfyPublisher.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.localPWAServer.updateSnapshot(snapshot)
        }
        ntfyPublisher.publish(store.providers, secret: pairing.currentSecret)
        localPWAServer.onURLChange = { [weak self] in self?.refreshPairingQRCode() }
        localPWAServer.start(preferredPort: localServerPort)
        updater.checkForUpdatesInBackground()
        observation = store.$providers.sink { [weak self] providers in
            self?.updateStatusItem(providers)
            guard let self else { return }
            self.ntfyPublisher.publish(providers, secret: self.pairing.currentSecret)
        }
        enabledProvidersObservation = store.$enabledProviderKinds.sink { [weak self] _ in
            guard let self else { return }
            self.updateStatusItem(self.store.providers)
        }
        hiddenWindowsObservation = store.$hiddenWindowTitlesByProvider.sink { [weak self] _ in
            guard let self, let provider = self.activeCardProvider else { return }
            self.showCard(for: provider, index: self.activeCardIndex)
        }
        // A provider can be added to or dropped from `visibleProviders` after launch (e.g.
        // its very first refresh confirms or rules it out just after `configureSidebar()`
        // sized the rail for whatever was known at that instant) — keep the panel's own
        // frame in sync so it doesn't linger at a stale size.
        visibleProvidersObservation = store.$visibleProviders
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] _ in self?.resizeSidebarPanels() }
        applyNotchVisibility()
        applyMenuBarVisibility()
        statusItem.menu = buildAppMenu()
        presentOnboardingIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseNotchPanels()
    }

    private var ntfyServer: String {
        get { UserDefaults.standard.string(forKey: "ntfyServer") ?? "https://ntfy.sh" }
        set { UserDefaults.standard.set(newValue, forKey: "ntfyServer") }
    }

    private var localServerPort: UInt16 {
        get {
            let port = UserDefaults.standard.integer(forKey: "localPWAServerPort")
            return UInt16(port == 0 ? 8973 : port)
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: "localPWAServerPort") }
    }

    private var customPWAURL: String {
        get {
            UserDefaults.standard.object(forKey: "customPWAURL") as? String
                ?? PairingManager.defaultRemotePWAURL
        }
        set { UserDefaults.standard.set(newValue, forKey: "customPWAURL") }
    }

    private var menuBarAlertColorsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "menuBarAlertColorsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "menuBarAlertColorsEnabled") }
    }

    private var showMenuBarProviderNames: Bool {
        get {
            UserDefaults.standard.object(forKey: "showMenuBarProviderNames") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "showMenuBarProviderNames") }
    }

    private func setShowMenuBarProviderNames(_ enabled: Bool) {
        showMenuBarProviderNames = enabled
        updateStatusItem(store.providers)
    }

    private var menuBarAlertSettings: MenuBarAlertSettings {
        MenuBarAlertSettings.load()
    }

    private var providerColors: [ProviderKind: NSColor] {
        Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { ($0, ProviderAppearance.color(for: $0)) })
    }

    private func refreshProviderAppearance() {
        updateStatusItem(store.providers)
        sidebarWindows.forEach { $0.contentView = makeHostingView() }
        if cardWindow != nil, let activeCardProvider {
            showCard(for: activeCardProvider, index: activeCardIndex)
        }
        popover?.contentViewController = NSHostingController(
            rootView: PopoverContent(store: store, alertSettings: menuBarAlertSettings)
        )
    }

    private func setMenuBarAlertColorsEnabled(_ enabled: Bool) {
        menuBarAlertColorsEnabled = enabled
        refreshProviderAppearance()
    }

    private func setMenuBarAlertSettings(_ settings: MenuBarAlertSettings) {
        UserDefaults.standard.set(settings.cautionThreshold, forKey: "menuBarCautionThreshold")
        UserDefaults.standard.set(settings.warningThreshold, forKey: "menuBarWarningThreshold")
        UserDefaults.standard.set(settings.criticalThreshold, forKey: "menuBarCriticalThreshold")
        saveMenuBarAlertColor(settings.cautionColor, forKey: "menuBarCautionColor")
        saveMenuBarAlertColor(settings.warningColor, forKey: "menuBarWarningColor")
        saveMenuBarAlertColor(settings.criticalColor, forKey: "menuBarCriticalColor")
        updateStatusItem(store.providers)
        sidebarWindows.forEach { $0.contentView = makeHostingView() }
        popover?.contentViewController = NSHostingController(
            rootView: PopoverContent(store: store, alertSettings: menuBarAlertSettings)
        )
    }

    private func menuBarAlertColor(forKey key: String, fallback: NSColor) -> NSColor {
        guard let data = UserDefaults.standard.data(forKey: key) else { return fallback }
        return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data))
            ?? fallback
    }

    private func saveMenuBarAlertColor(_ color: NSColor, forKey key: String) {
        guard
            let data = try? NSKeyedArchiver.archivedData(
                withRootObject: color, requiringSecureCoding: true)
        else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func menuBarAlertColor(for percent: Double) -> NSColor? {
        guard menuBarAlertColorsEnabled else { return nil }
        let settings = menuBarAlertSettings
        if percent >= Double(settings.criticalThreshold) { return settings.criticalColor }
        if percent >= Double(settings.warningThreshold) { return settings.warningColor }
        if percent >= Double(settings.cautionThreshold) { return settings.cautionColor }
        return nil
    }

    private var pwaBaseURL: String? {
        let customURL = customPWAURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: customURL), url.scheme == "https", url.host != nil {
            return customURL.hasSuffix("/") ? String(customURL.dropLast()) : customURL
        }
        return localPWAServer.baseURL?.absoluteString
    }

    /// The Mac's LAN address, independent of `pwaBaseURL`'s hosted-vs-local fallback, so
    /// the pairing link can carry it even when a custom HTTPS PWA URL is configured.
    private var localServerURL: String? { localPWAServer.baseURL?.absoluteString }

    private func refreshPairingQRCode() {
        guard let pwaBaseURL else { return }
        pairing.refreshQRCode(pwaBaseURL: pwaBaseURL, ntfyServer: ntfyServer, localURL: localServerURL)
    }

    private func regeneratePairing() {
        pairing.regenerate()
        localPWAServer.setSnapshotTokens([pairing.currentSnapshotToken, pairing.currentLocalToken])
        refreshPairingQRCode()
        ntfyPublisher.publish(store.providers, secret: pairing.currentSecret)
    }

    private func updateStatusItem(_ providers: [ProviderUsage]) {
        let title = NSMutableAttributedString()
        let usages = providers.sorted { $0.kind.rawValue < $1.kind.rawValue }.filter {
            store.enabledProviderKinds.contains($0.kind)
        }

        for (index, usage) in usages.enumerated() {
            if index > 0 {
                title.append(
                    NSAttributedString(
                        string: "  ·  ",
                        attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]))
            }
            if let logo = ProviderAppearance.logo(for: usage.kind) {
                let attachment = NSTextAttachment()
                attachment.image = logo
                attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                title.append(NSAttributedString(attachment: attachment))
                title.append(NSAttributedString(string: " "))
            }
            if showMenuBarProviderNames {
                let name = usage.kind == .openCodeGo ? "Go" : usage.kind.rawValue
                title.append(
                    NSAttributedString(
                        string: "\(name) ",
                        attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]))
            }
            if let primary = usage.primary {
                var percentageAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
                ]
                if let color = menuBarAlertColor(for: primary.percent) {
                    percentageAttributes[.foregroundColor] = color
                }
                title.append(
                    NSAttributedString(
                        string: "\(Int(primary.percent.rounded()))%", attributes: percentageAttributes))
            } else {
                title.append(
                    NSAttributedString(
                        string: "--", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]))
            }
        }
        statusItem.button?.image = nil
        statusItem.button?.attributedTitle =
            usages.isEmpty ? NSAttributedString(string: "--") : title
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = nil
        statusItem.button?.title = "--"
        statusItem.button?.font = .systemFont(ofSize: 13, weight: .semibold)
        statusItem.menu = buildAppMenu()
    }

    private func buildAppMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: String(localized: "Open dashboard"), action: #selector(togglePopover), keyEquivalent: "",
            symbolName: "rectangle.dock")
        let notchItem = menu.addItem(
            withTitle: String(localized: "Show notch"), action: #selector(toggleNotchVisibility), keyEquivalent: "",
            symbolName: "capsule")
        notchItem.state = showsNotch ? .on : .off
        notchItem.isEnabled = !(showsNotch && !showsMenuBar)
        let menuBarItem = menu.addItem(
            withTitle: String(localized: "Show in menu bar"), action: #selector(toggleMenuBarVisibility),
            keyEquivalent: "", symbolName: "menubar.rectangle")
        menuBarItem.state = showsMenuBar ? .on : .off
        menuBarItem.isEnabled = !(showsMenuBar && !showsNotch)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",",
            symbolName: "gearshape")
        if updater.isConfigured {
            menu.addItem(
                withTitle: String(localized: "Check for Updates…"), action: #selector(AppUpdater.checkForUpdates(_:)),
                keyEquivalent: "", symbolName: "arrow.trianglehead.2.clockwise")
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Quit"), action: #selector(quit), keyEquivalent: "q", symbolName: "power")
        menu.items.forEach { $0.target = self }
        if updater.isConfigured {
            menu.items.first { $0.action == #selector(AppUpdater.checkForUpdates(_:)) }?.target =
                updater
        }
        return menu
    }

    private func showNotchMenu(at windowPoint: NSPoint) {
        let panel =
            sidebarWindows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? sidebarWindow
        guard let panel, let contentView = panel.contentView else { return }
        let anchor = contentView.convert(windowPoint, from: nil)
        buildNotchMenu().popUp(positioning: nil, at: anchor, in: contentView)
    }

    /// Same as `buildAppMenu()`, with a "Position" submenu inserted for switching which
    /// screen edge the notch anchors to — handy right where you're already looking at it,
    /// without a trip through Settings.
    private func buildNotchMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: String(localized: "Open dashboard"), action: #selector(togglePopover), keyEquivalent: "",
            symbolName: "rectangle.dock")
        let notchItem = menu.addItem(
            withTitle: String(localized: "Show notch"), action: #selector(toggleNotchVisibility), keyEquivalent: "",
            symbolName: "capsule")
        notchItem.state = showsNotch ? .on : .off
        notchItem.isEnabled = !(showsNotch && !showsMenuBar)
        let menuBarItem = menu.addItem(
            withTitle: String(localized: "Show in menu bar"), action: #selector(toggleMenuBarVisibility),
            keyEquivalent: "", symbolName: "menubar.rectangle")
        menuBarItem.state = showsMenuBar ? .on : .off
        menuBarItem.isEnabled = !(showsMenuBar && !showsNotch)

        let positionItem = menu.addItem(withTitle: String(localized: "Position"), action: nil, keyEquivalent: "")
        positionItem.image = NSImage(
            systemSymbolName: "square.dashed.inset.filled", accessibilityDescription: nil)
        let positionMenu = NSMenu()
        for position in NotchPosition.allCases {
            let item = positionMenu.addItem(
                withTitle: position.title, action: #selector(selectNotchPositionFromMenu(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = position.rawValue
            item.state = notchMode.position == position ? .on : .off
        }
        positionItem.submenu = positionMenu

        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",",
            symbolName: "gearshape")
        if updater.isConfigured {
            menu.addItem(
                withTitle: String(localized: "Check for Updates…"), action: #selector(AppUpdater.checkForUpdates(_:)),
                keyEquivalent: "", symbolName: "arrow.trianglehead.2.clockwise")
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Quit"), action: #selector(quit), keyEquivalent: "q", symbolName: "power")
        menu.items.forEach { $0.target = self }
        if updater.isConfigured {
            menu.items.first { $0.action == #selector(AppUpdater.checkForUpdates(_:)) }?.target =
                updater
        }
        return menu
    }

    @objc private func selectNotchPositionFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let position = NotchPosition(rawValue: raw)
        else { return }
        setNotchPosition(position)
    }

    private func configurePopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 440, height: 700)
        popover.contentViewController = NSHostingController(
            rootView: PopoverContent(store: store, alertSettings: menuBarAlertSettings)
        )
    }

    private var notchGeometry = NotchGeometry.current()
    private let notchMode = NotchMode()
    private var notchMetrics: NotchMetrics {
        NotchMetrics(size: notchMode.size, providerCount: store.visibleProviders.count)
    }
    private var notchExpansion: CGFloat {
        notchMetrics.controlsHeight + notchMetrics.controlsGap + notchMetrics.controlsBottomSpace
    }
    private var notchScreens: [NotchScreen] {
        NSScreen.screens.compactMap { screen in
            guard
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber
            else { return nil }
            return NotchScreen(id: id.uint32Value, name: screen.localizedName)
        }
    }
    private var selectedNotchScreen: NSScreen? {
        let selectedID = UserDefaults.standard.object(forKey: "notchScreenID") as? NSNumber
        return NSScreen.screens.first { screen in
            guard
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber
            else { return false }
            return id.uint32Value == selectedID?.uint32Value
        } ?? NSScreen.main ?? NSScreen.screens.first
    }
    private var selectedNotchScreenID: UInt32 {
        guard let screen = selectedNotchScreen,
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return 0 }
        return id.uint32Value
    }
    private var sidebarWindows: [NSPanel] = []
    private var cardWindow: NSPanel?
    private var activeCardProvider: ProviderKind?
    private var activeCardIndex = 0
    private var activeCardScreen: NSScreen?
    private var hoveredProvider: ProviderKind?
    private var isRailHovered = false
    private var isCardHovered = false
    private var pendingCardDismiss: DispatchWorkItem?
    private var pendingCardShow: DispatchWorkItem?

    /// The window is always created at its full hover size, so a vertical pill's window
    /// is shifted up by `notchExpansion` to pre-reserve that extra room evenly split above
    /// and below the compact rail's fixed center — `NotchContent` centers its content on
    /// that same axis, so the rail neither moves nor needs its own compensating offset. A
    /// horizontal bar needs none: it already grows centered on its width axis for free.
    private var notchExpansionOffset: CGFloat {
        notchMode.position.axis == .vertical ? notchExpansion : 0
    }
    private var notchPanelExtent: CGFloat {
        notchMetrics.hoverHeight + notchMetrics.interactionMargin * 2
    }
    private var notchPanelOffsetAdjustment: CGFloat {
        notchMode.position.axis == .vertical ? notchMetrics.interactionMargin : 0
    }
    private var defaultNotchPanelOffset: CGFloat {
        notchExpansionOffset + notchPanelOffsetAdjustment
    }
    private var currentNotchPanelOffset: CGFloat {
        notchAlongEdgeOffset + defaultNotchPanelOffset
    }

    private func configureSidebar() {
        releaseNotchPanels()
        let screen = selectedNotchScreen ?? NSScreen.main ?? NSScreen.screens.first
        sidebarWindows = screen.map { [makeSidebarWindow(for: $0)] } ?? []
        sidebarWindow = sidebarWindows.first
        notchGeometry = NotchGeometry.current(for: screen, position: notchMode.position)

        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func releaseNotchPanels() {
        resetNotchInteractionState()
        cardWindow?.contentViewController = nil
        cardWindow?.close()
        cardWindow = nil
        sidebarWindows.forEach {
            $0.contentView = nil
            $0.close()
        }
        sidebarWindows.removeAll()
        sidebarWindow = nil
    }

    private func makeSidebarWindow(for screen: NSScreen) -> NSPanel {
        let geometry = NotchGeometry.current(for: screen, position: notchMode.position)
        let frame = geometry.frame(
            thickness: notchMetrics.idleWidth, extent: notchPanelExtent,
            alongEdgeOffset: currentNotchPanelOffset)
        let panel = DraggableNotchPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.metrics = notchMetrics
        panel.position = notchMode.position
        panel.onDragMove = { [weak self] delta in self?.moveNotch(by: delta) }
        panel.onGearTap = { [weak self] _ in self?.openSettingsFromNotch() }
        panel.onEyeTap = { [weak self] in
            guard let self else { return }
            self.setHiddenNotch(!self.notchMode.isHiddenMode)
        }
        panel.onContextMenu = { [weak self] point in self?.showNotchMenu(at: point) }
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.alphaValue = 1
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.contentView = makeHostingView()
        panel.setFrame(frame, display: true)
        return panel
    }

    private func moveNotchToSelectedScreen() {
        guard showsNotch, let sidebarWindow, let screen = selectedNotchScreen else { return }
        let axis = notchMode.position.axis
        let geometry = NotchGeometry.current(for: screen, position: notchMode.position)
        let defaultFrame = geometry.frame(
            thickness: notchMetrics.idleWidth, extent: notchPanelExtent,
            alongEdgeOffset: defaultNotchPanelOffset)
        var frame = geometry.frame(
            thickness: notchMetrics.idleWidth, extent: notchPanelExtent,
            alongEdgeOffset: currentNotchPanelOffset)
        if axis == .vertical {
            frame.origin.y = min(
                max(frame.origin.y, screen.visibleFrame.minY),
                screen.visibleFrame.maxY - frame.height)
        } else {
            frame.origin.x = min(
                max(frame.origin.x, screen.visibleFrame.minX),
                screen.visibleFrame.maxX - frame.width)
        }
        guard !frame.equalTo(sidebarWindow.frame) else {
            notchGeometry = geometry
            return
        }
        sidebarWindow.setFrame(frame, display: true)
        notchGeometry = geometry
        notchAlongEdgeOffset =
            axis == .vertical
            ? frame.origin.y - defaultFrame.origin.y : frame.origin.x - defaultFrame.origin.x
    }

    // Building a fresh hosting view resets the SwiftUI hover state so that, on hiding,
    // the rail truly collapses to the slim bar instead of staying expanded under the cursor.
    private func makeHostingView() -> NotchHostingView {
        let content = NotchContent(
            store: store,
            mode: notchMode,
            backgroundOpacity: sidebarOpacity,
            onNotchHover: { [weak self] isHovered in self?.setRailHovered(isHovered) },
            onProviderHover: { [weak self] provider, index, isHovered in
                self?.setProviderHovered(provider, index: index, isHovered: isHovered)
            },
            onProviderTap: { [weak self] _ in self?.showPopoverFromNotch() }
        )
        let hostingView = NotchHostingView(rootView: content)
        hostingView.isHiddenMode = notchMode.isHiddenMode
        hostingView.metrics = notchMetrics
        hostingView.position = notchMode.position
        return hostingView
    }

    // Displays can be connected/disconnected or change resolution at any time; recompute
    // the notch's real position and snap back to it unless the shelf is mid-interaction.
    @objc private func screenParametersDidChange() {
        moveNotchToSelectedScreen()
        if activeCardProvider != nil {
            positionCard(index: activeCardIndex)
        }
    }

    private var notchAlongEdgeOffset: CGFloat {
        get { UserDefaults.standard.object(forKey: "notchAlongEdgeOffset") as? CGFloat ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: "notchAlongEdgeOffset") }
    }

    // Keep the notch inside the visible frame while dragging, and preserve the offset so
    // the user's preferred position along its anchor edge survives relaunches. The drag
    // delta itself is already measured along the right axis by `DraggableNotchPanel`.
    private func moveNotch(by delta: CGFloat) {
        guard let sidebarWindow else { return }
        let screen =
            sidebarWindow.screen ?? NSScreen.screens.first {
                $0.frame.intersects(sidebarWindow.frame)
            } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? sidebarWindow.frame
        var frame = sidebarWindow.frame
        let axis = notchMode.position.axis
        if axis == .vertical {
            frame.origin.y = min(
                max(frame.origin.y + delta, visibleFrame.minY), visibleFrame.maxY - frame.height)
        } else {
            frame.origin.x = min(
                max(frame.origin.x + delta, visibleFrame.minX), visibleFrame.maxX - frame.width)
        }
        sidebarWindow.setFrameOrigin(frame.origin)

        notchGeometry = NotchGeometry.current(for: screen, position: notchMode.position)
        let defaultFrame = notchGeometry.frame(
            thickness: notchMetrics.idleWidth, extent: notchPanelExtent,
            alongEdgeOffset: defaultNotchPanelOffset)
        notchAlongEdgeOffset =
            axis == .vertical
            ? frame.origin.y - defaultFrame.origin.y : frame.origin.x - defaultFrame.origin.x
        if activeCardProvider != nil { positionCard(index: activeCardIndex) }
    }

    private func setRailHovered(_ isHovered: Bool) {
        guard isRailHovered != isHovered else { return }
        isRailHovered = isHovered
        (sidebarWindow?.contentView as? NotchHostingView)?.isHovered = isHovered
        if isHovered {
            pendingCardDismiss?.cancel()
        } else {
            scheduleCardDismiss()
        }
    }

    private func setHiddenNotch(_ isHidden: Bool) {
        UserDefaults.standard.set(isHidden, forKey: "hiddenNotch")
        guard notchMode.isHiddenMode != isHidden else { return }
        notchMode.isHiddenMode = isHidden
        isCardHovered = false
        hoveredProvider = nil
        activeCardProvider = nil
        cardWindow?.orderOut(nil)
        if isHidden {
            isRailHovered = false
            // Fresh view resets the SwiftUI hover state so the rail collapses at once.
            for window in sidebarWindows {
                window.contentView = makeHostingView()
            }
        }
    }

    private func setNotchSize(_ size: NotchSize) {
        guard notchMode.size != size else { return }
        notchMode.size = size
        UserDefaults.standard.set(size.rawValue, forKey: "notchSize")
        resizeSidebarPanels()
    }

    /// Re-applies `notchMetrics` (which itself derives from `store.visibleProviders.count`)
    /// to every sidebar panel's frame and hosting view. Shared by explicit size changes and
    /// by the `visibleProviders` observer, since both need the panel to track whatever row
    /// count is currently true rather than whatever it was sized for at creation time.
    private func resizeSidebarPanels() {
        for window in sidebarWindows {
            (window as? DraggableNotchPanel)?.metrics = notchMetrics
            if let hostingView = window.contentView as? NotchHostingView {
                hostingView.metrics = notchMetrics
                hostingView.needsLayout = true
            }
            let screen = NSScreen.screens.first { $0.frame.intersects(window.frame) }
            let geometry = NotchGeometry.current(for: screen, position: notchMode.position)
            window.setFrame(
                geometry.frame(
                    thickness: notchMetrics.idleWidth, extent: notchPanelExtent,
                    alongEdgeOffset: currentNotchPanelOffset), display: true)
        }
        if let activeCardProvider {
            showCard(for: activeCardProvider, index: activeCardIndex)
        }
    }

    private func setNotchScreen(_ id: UInt32) {
        UserDefaults.standard.set(Int(id), forKey: "notchScreenID")
        moveNotchToSelectedScreen()
        if activeCardProvider != nil { positionCard(index: activeCardIndex) }
    }

    private var notchBehavior: NotchBehavior {
        notchMode.isHiddenMode ? .autoHide : .pinned
    }

    private func setNotchBehavior(_ behavior: NotchBehavior) {
        setHiddenNotch(behavior == .autoHide)
    }

    // Switching axis makes a saved along-edge offset meaningless (a vertical drag offset
    // has no sensible horizontal equivalent), so dragging starts over from center/top.
    private func setNotchPosition(_ position: NotchPosition) {
        guard notchMode.position != position else { return }
        notchMode.position = position
        UserDefaults.standard.set(position.rawValue, forKey: "notchPosition")
        notchAlongEdgeOffset = 0
        for window in sidebarWindows {
            (window as? DraggableNotchPanel)?.position = position
            if let hostingView = window.contentView as? NotchHostingView {
                hostingView.position = position
                hostingView.needsLayout = true
            }
            let screen =
                NSScreen.screens.first { $0.frame.intersects(window.frame) } ?? selectedNotchScreen
            let geometry = NotchGeometry.current(for: screen, position: position)
            window.setFrame(
                geometry.frame(
                    thickness: notchMetrics.idleWidth, extent: notchPanelExtent,
                    alongEdgeOffset: defaultNotchPanelOffset), display: true)
            notchGeometry = geometry
        }
        if let activeCardProvider {
            showCard(for: activeCardProvider, index: activeCardIndex)
        }
    }

    private func setProviderHovered(_ provider: ProviderKind, index: Int, isHovered: Bool) {
        if isHovered {
            hoveredProvider = provider
            isRailHovered = true
            pendingCardDismiss?.cancel()
            pendingCardShow?.cancel()
            if activeCardProvider != nil {
                // A card is already on screen for another provider — switch right away.
                // The settle delay below only matters for the very first reveal, while
                // the shell itself is still mid-expansion.
                showCard(for: provider, index: index)
            } else {
                // Wait for the shell's own hover spring to settle before revealing the card,
                // so it doesn't pop in ahead of the notch finishing its expand animation.
                let workItem = DispatchWorkItem { [weak self] in
                    self?.showCard(for: provider, index: index)
                }
                pendingCardShow = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
            }
        } else {
            pendingCardShow?.cancel()
            if hoveredProvider == provider {
                hoveredProvider = nil
            }
        }
    }

    private func setCardHovered(_ isHovered: Bool) {
        isCardHovered = isHovered
        if isHovered {
            pendingCardDismiss?.cancel()
        } else {
            scheduleCardDismiss()
        }
    }

    private func scheduleCardDismiss() {
        pendingCardDismiss?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isRailHovered, !self.isCardHovered else { return }
            self.activeCardProvider = nil
            guard let cardWindow = self.cardWindow else { return }
            let exitFrame = self.railwardFrame(cardWindow.frame, offset: 8)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                // A plain, gentle dissolve — no shrink, just alpha easing smoothly to nothing
                // while it drifts back toward the rail it came from.
                cardWindow.animator().alphaValue = 0
                cardWindow.animator().setFrame(exitFrame, display: true)
            } completionHandler: { [weak self] in
                // Only hide the panel if nothing re-showed it for another provider while
                // the fade-out was still running.
                Task { @MainActor in
                    guard let self, self.activeCardProvider == nil else { return }
                    cardWindow.orderOut(nil)
                }
            }
        }
        pendingCardDismiss = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func showCard(for provider: ProviderKind, index: Int) {
        let usage =
            store.providers.first(where: { $0.kind == provider })
            ?? ProviderUsage(kind: provider, windows: [], updatedAt: nil, error: nil)
        let isAlreadyVisible = cardWindow?.isVisible == true

        if cardWindow == nil {
            let window = NSPanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovable = false
            cardWindow = window
        }
        guard let cardWindow else { return }

        activeCardProvider = provider
        activeCardIndex = index
        activeCardScreen = selectedNotchScreen
        notchGeometry = NotchGeometry.current(for: activeCardScreen, position: notchMode.position)
        let cardContent = NotchCardContent(
            usage: usage,
            hiddenWindowTitles: store.hiddenWindowTitlesByProvider[provider] ?? [],
            metrics: notchMetrics,
            position: notchMode.position,
            backgroundOpacity: sidebarOpacity
        ) { [weak self] isHovered in
            self?.setCardHovered(isHovered)
        }

        if isAlreadyVisible,
            let hostingController = cardWindow.contentViewController
                as? NSHostingController<NotchCardContent>
        {
            // Already on screen for a previous provider — spring the SwiftUI content over to
            // the new provider's data in place (see `NotchCardContent.card`'s `.id`/
            // `.transition`) instead of hard-cutting, since that read as dead/inert.
            withAnimation(.spring(response: 0.14, dampingFraction: 0.82)) {
                hostingController.rootView = cardContent
            }
        } else {
            cardWindow.contentViewController = NSHostingController(rootView: cardContent)
        }
        cardWindow.layoutIfNeeded()
        let cardHeight = max(cardWindow.contentViewController?.view.fittingSize.height ?? 0, 1)
        let finalFrame = cardFrame(index: index, height: cardHeight)

        if isAlreadyVisible {
            // Spring the window itself over to the newly hovered row so it travels with the
            // content crossfade above instead of teleporting there instantly.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.3, 1.1, 0.4, 1)
                cardWindow.animator().setFrame(finalFrame, display: true)
            }
            cardWindow.alphaValue = 1
            cardWindow.orderFrontRegardless()
        } else {
            // First reveal: pop the card out from behind the rail with a slide, a springy
            // overshoot scale, and a fade, so it reads as emerging from the notch instead of
            // just appearing.
            let startFrame = railwardFrame(finalFrame, offset: 14)
            cardWindow.setFrame(startFrame, display: true)
            setCardScale(0.87, on: cardWindow, anchor: cardScaleAnchor(for: notchMode.position))
            cardWindow.alphaValue = 0
            cardWindow.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.07
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cardWindow.animator().alphaValue = 1
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.32, 1.4, 0.5, 1)
                cardWindow.animator().setFrame(finalFrame, display: true)
                cardWindow.contentView?.layer?.transform = CATransform3DIdentity
            }
        }
    }

    /// Shifts `frame`'s origin toward the rail's anchor edge by `offset` — used to start the
    /// entrance slide from behind the rail, and to slide the card back into it on dismiss.
    private func railwardFrame(_ frame: NSRect, offset: CGFloat) -> NSRect {
        var frame = frame
        switch notchMode.position {
        case .right: frame.origin.x += offset
        case .left: frame.origin.x -= offset
        case .top: frame.origin.y += offset
        case .bottom: frame.origin.y -= offset
        }
        return frame
    }

    /// Which edge of the card sits flush against the rail, so the entrance scale grows out of
    /// that edge instead of from the card's own center, matching the slide direction.
    private func cardScaleAnchor(for position: NotchPosition) -> CGPoint {
        switch position {
        case .right: CGPoint(x: 1, y: 0.5)
        case .left: CGPoint(x: 0, y: 0.5)
        case .bottom: CGPoint(x: 0.5, y: 0)
        case .top: CGPoint(x: 0.5, y: 1)
        }
    }

    /// Re-anchors the card window's content layer to `anchor` (compensating `position` so the
    /// frame doesn't visually jump) and jumps its model transform straight to `scale` with no
    /// implicit animation, so a later animated assignment of `.transform = .identity` reads as
    /// growing out from that anchor.
    private func setCardScale(_ scale: CGFloat, on window: NSPanel, anchor: CGPoint) {
        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        guard let layer = contentView.layer else { return }
        let bounds = layer.bounds
        let oldAnchor = layer.anchorPoint
        layer.anchorPoint = anchor
        layer.position.x += (anchor.x - oldAnchor.x) * bounds.width
        layer.position.y += (anchor.y - oldAnchor.y) * bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    /// Attaches the detail card to whichever side of the rail has room to grow into the
    /// screen: beside it for a vertical pill (left of a right-anchored rail, right of a
    /// left-anchored one), above/below it for a horizontal bar (below a top-anchored bar,
    /// above a bottom-anchored one — the bar itself already sits flush against that edge).
    private func positionCard(index: Int, height: CGFloat? = nil) {
        guard let cardWindow else { return }
        let cardHeight =
            height ?? max(cardWindow.contentViewController?.view.fittingSize.height ?? 0, 1)
        cardWindow.setFrame(cardFrame(index: index, height: cardHeight), display: true)
    }

    /// Computes the card's resting frame beside (vertical rail) or above/below (horizontal
    /// bar) the given provider row, clamped to the visible screen area. Pulled out of
    /// `positionCard` so `showCard` can also derive an off-position starting frame for the
    /// reveal animation.
    private func cardFrame(index: Int, height cardHeight: CGFloat) -> NSRect {
        let position = notchMode.position
        let leadInset = 12 * notchMetrics.scale
        let itemStride = notchMetrics.providerItemHeight + notchMetrics.providerSpacing
        let visibleFrame =
            activeCardScreen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? notchGeometry.frame(
                thickness: notchMetrics.idleWidth, extent: notchMetrics.railExtent,
                alongEdgeOffset: notchAlongEdgeOffset)

        switch position.axis {
        case .vertical:
            let railFrame = notchGeometry.frame(
                thickness: notchMetrics.idleWidth, extent: notchMetrics.railExtent,
                alongEdgeOffset: notchAlongEdgeOffset)
            let providerCenterY =
                railFrame.maxY - notchMetrics.squareSideExtension - leadInset
                - notchMetrics.providerItemHeight / 2 - CGFloat(index)
                * itemStride
            let originY = min(
                max(providerCenterY - cardHeight / 2, visibleFrame.minY + 8),
                visibleFrame.maxY - cardHeight - 8)
            let originX =
                position == .right
                ? railFrame.minX - notchMetrics.cardWidth - notchMetrics.cardSpacing
                : railFrame.maxX + notchMetrics.cardSpacing
            return NSRect(x: originX, y: originY, width: notchMetrics.cardWidth, height: cardHeight)
        case .horizontal:
            let railFrame = notchGeometry.frame(
                thickness: notchMetrics.idleWidth, extent: notchMetrics.railExtent,
                alongEdgeOffset: notchAlongEdgeOffset)
            let providerCenterX =
                railFrame.minX + notchMetrics.squareSideExtension + leadInset
                + notchMetrics.providerItemHeight / 2 + CGFloat(index)
                * itemStride
            let originX = min(
                max(providerCenterX - notchMetrics.cardWidth / 2, visibleFrame.minX + 8),
                visibleFrame.maxX - notchMetrics.cardWidth - 8)
            let originY =
                position == .bottom
                ? railFrame.maxY + notchMetrics.cardSpacing
                : railFrame.minY - cardHeight - notchMetrics.cardSpacing
            return NSRect(x: originX, y: originY, width: notchMetrics.cardWidth, height: cardHeight)
        }
    }

    private var sidebarOpacity: Double {
        get { UserDefaults.standard.object(forKey: "sidebarOpacity") as? Double ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "sidebarOpacity") }
    }

    private func setSidebarOpacity(_ opacity: Double) {
        sidebarOpacity = opacity
        sidebarWindows.forEach { window in
            window.alphaValue = 1
            window.contentView = makeHostingView()
        }
        if let activeCardProvider {
            showCard(for: activeCardProvider, index: activeCardIndex)
        }
    }

    // The notch and the menu bar are independent — either, both, or (via the UI guard
    // below) never neither can be visible at once.
    private var showsNotch: Bool {
        get { UserDefaults.standard.object(forKey: "showsNotch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showsNotch") }
    }
    private var showsMenuBar: Bool {
        get { UserDefaults.standard.object(forKey: "showsMenuBar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showsMenuBar") }
    }

    /// One-time migration from the old mutually-exclusive `displayMode` key. Must run
    /// before anything reads `showsNotch`/`showsMenuBar` for the first time.
    private func migrateDisplayModeIfNeeded() {
        guard UserDefaults.standard.object(forKey: "showsNotch") == nil,
            UserDefaults.standard.object(forKey: "showsMenuBar") == nil
        else { return }
        if let legacyMode = UserDefaults.standard.string(forKey: "displayMode") {
            showsNotch = legacyMode != "menuBar"
            showsMenuBar = legacyMode == "menuBar"
        } else {
            showsNotch = true
            showsMenuBar = true
        }
        UserDefaults.standard.removeObject(forKey: "displayMode")
    }

    private func setShowsNotch(_ newValue: Bool) {
        guard newValue || showsMenuBar else { return }
        showsNotch = newValue
        applyNotchVisibility()
        statusItem.menu = buildAppMenu()
    }

    private func setShowsMenuBar(_ newValue: Bool) {
        guard newValue || showsNotch else { return }
        showsMenuBar = newValue
        applyMenuBarVisibility()
        statusItem.menu = buildAppMenu()
    }

    private func applyNotchVisibility() {
        if showsNotch {
            animateSidebarIn()
        } else {
            resetNotchInteractionState()
            sidebarWindows.forEach { $0.orderOut(nil) }
        }
    }

    private func applyMenuBarVisibility() {
        statusItem.isVisible = showsMenuBar
    }

    /// Shared by the show and hide paths so hover/card state never survives a
    /// visibility flip in either direction.
    private func resetNotchInteractionState() {
        isRailHovered = false
        isCardHovered = false
        hoveredProvider = nil
        activeCardProvider = nil
        pendingCardDismiss?.cancel()
        pendingCardShow?.cancel()
        cardWindow?.orderOut(nil)
    }

    private func animateSidebarIn() {
        guard !sidebarWindows.isEmpty else { return }
        let screen = selectedNotchScreen
        notchGeometry = NotchGeometry.current(for: screen, position: notchMode.position)
        resetNotchInteractionState()
        sidebarWindows.forEach { window in
            let geometry = NotchGeometry.current(for: screen, position: notchMode.position)
            let frame = geometry.frame(
                thickness: notchMetrics.idleWidth, extent: notchPanelExtent,
                alongEdgeOffset: currentNotchPanelOffset)
            window.setFrame(frame, display: true)
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
    }

    @objc private func toggleNotchVisibility() { setShowsNotch(!showsNotch) }
    @objc private func toggleMenuBarVisibility() { setShowsMenuBar(!showsMenuBar) }
    @objc func quit() { NSApp.terminate(nil) }

    private func reconnectProvider(_ kind: ProviderKind) {
        if kind == .cursor {
            guard let downloadURL = URL(string: "https://www.cursor.com/downloads") else { return }
            NSWorkspace.shared.open(downloadURL)
            return
        }

        let command = kind.reconnectCommand
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)

        let escapedCommand = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = "tell application \"Terminal\" to do script \"\(escapedCommand)\""
        Task.detached {
            var scriptError: NSDictionary?
            let didOpenTerminal =
                NSAppleScript(source: scriptSource)?.executeAndReturnError(&scriptError) != nil
            guard !didOpenTerminal else { return }
            await MainActor.run {
                _ = NSWorkspace.shared.open(
                    URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
            }
        }
    }

    private func settingsWindowForPresentation() -> NSWindow {
        settingsWindow
            ?? {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = String(localized: "Settings")
                window.isReleasedWhenClosed = false
                window.minSize = NSSize(width: 680, height: 500)
                window.center()
                settingsWindow = window
                return window
            }()
    }

    private func presentSettingsWindow(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func presentOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }

        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Metria"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(
                store: store,
                showsNotch: showsNotch,
                showsMenuBar: showsMenuBar,
                onToggleNotch: { [weak self] enabled in self?.setShowsNotch(enabled) },
                onToggleMenuBar: { [weak self] enabled in self?.setShowsMenuBar(enabled) },
                onReconnect: { [weak self] kind in self?.reconnectProvider(kind) },
                onFinish: { [weak self] in self?.finishOnboarding() }
            )
        )
        onboardingWindow = window
        window.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        onboardingWindow?.orderOut(nil)
        onboardingWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func openSettingsFromNotch() {
        guard !notchMode.isOpeningSettings else { return }
        notchMode.isOpeningSettings = true

        let window = settingsWindowForPresentation()
        window.contentViewController = NSHostingController(rootView: SettingsLoadingView())
        presentSettingsWindow(window)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.openSettings()
            self.notchMode.isOpeningSettings = false
        }
    }

    @objc private func openSettings() {
        let window = settingsWindowForPresentation()
        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                store: store,
                pairing: pairing,
                showsNotch: showsNotch,
                onToggleNotch: { [weak self] enabled in self?.setShowsNotch(enabled) },
                showsMenuBar: showsMenuBar,
                onToggleMenuBar: { [weak self] enabled in self?.setShowsMenuBar(enabled) },
                notchScreens: notchScreens,
                notchScreenID: selectedNotchScreenID,
                onSelectNotchScreen: { [weak self] id in self?.setNotchScreen(id) },
                notchBehavior: notchBehavior,
                onSelectNotchBehavior: { [weak self] behavior in self?.setNotchBehavior(behavior) },
                notchSize: notchMode.size,
                onSelectNotchSize: { [weak self] size in self?.setNotchSize(size) },
                notchPosition: notchMode.position,
                onSelectNotchPosition: { [weak self] position in self?.setNotchPosition(position) },
                providerColors: providerColors,
                onChangeProviderAppearance: { [weak self] in self?.refreshProviderAppearance() },
                menuBarAlertColorsEnabled: menuBarAlertColorsEnabled,
                 onChangeMenuBarAlertColors: { [weak self] enabled in
                     self?.setMenuBarAlertColorsEnabled(enabled)
                 },
                 onChangeMenuBarProviderNames: { [weak self] enabled in
                     self?.setShowMenuBarProviderNames(enabled)
                 },
                menuBarAlertSettings: menuBarAlertSettings,
                onChangeMenuBarAlertSettings: { [weak self] settings in
                    self?.setMenuBarAlertSettings(settings)
                },
                sidebarOpacity: sidebarOpacity,
                onChangeSidebarOpacity: { [weak self] opacity in self?.setSidebarOpacity(opacity) },
                launchAtLoginEnabled: LaunchAtLoginManager.isEnabled,
                onChangeLaunchAtLogin: { enabled in LaunchAtLoginManager.setEnabled(enabled) },
                onQuit: { [weak self] in self?.quit() },
                onReconnect: { [weak self] kind in self?.reconnectProvider(kind) },
                ntfyServer: ntfyServer,
                onChangeServer: { [weak self] server in
                    guard let self else { return }
                    self.ntfyServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.refreshPairingQRCode()
                    self.store.refresh()
                },
                localPWAURL: { [weak self] in self?.pwaBaseURL },
                localServerURL: { [weak self] in self?.localServerURL },
                localServerPort: localServerPort,
                onChangeLocalServerPort: { [weak self] port in
                    guard let self else { return }
                    self.localServerPort = port
                    self.localPWAServer.start(preferredPort: port)
                },
                customPWAURL: customPWAURL,
                onChangeCustomPWAURL: { [weak self] url in
                    guard let self else { return }
                    self.customPWAURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.refreshPairingQRCode()
                },
                onRegeneratePairing: { [weak self] in self?.regeneratePairing() },
                canCheckForUpdates: updater.isConfigured,
                onCheckForUpdates: { [weak self] in self?.updater.checkForUpdates(nil) }
            ))
        presentSettingsWindow(window)
    }

    // Notch and menu bar can both be visible at once, so the anchor can't be inferred
    // solely from which surfaces are visible: a tap inside the notch should always
    // anchor there even if the menu bar item also happens to be showing.
    @objc func togglePopover() { togglePopoverPreferringNotchAnchor(false) }

    private func showPopoverFromNotch() { togglePopoverPreferringNotchAnchor(true) }

    private func togglePopoverPreferringNotchAnchor(_ preferNotchAnchor: Bool) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if preferNotchAnchor, showsNotch, let contentView = sidebarWindow.contentView {
            popover.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minX)
        } else if statusItem.isVisible, let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let contentView = sidebarWindow.contentView {
            popover.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minX)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === onboardingWindow else { return true }
        finishOnboarding()
        return true
    }
}

@main struct MetriaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}
