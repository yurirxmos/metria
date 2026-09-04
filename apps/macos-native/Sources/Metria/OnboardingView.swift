import AppKit
import MetriaCore
import SwiftUI

struct OnboardingView: View {
    private enum Step: Int, CaseIterable {
        case welcome
        case providers
        case display
        case ready

        var title: String {
            switch self {
            case .welcome: "Welcome to Metria"
            case .providers: "Connect your providers"
            case .display: "Choose where to see Metria"
            case .ready: "You are ready to go"
            }
        }
    }

    @ObservedObject var store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = Step.welcome
    @State private var showsNotch: Bool
    @State private var showsMenuBar: Bool
    @State private var mascotIsFloating = false
    @State private var providerCheckTimedOut = false

    let onToggleNotch: (Bool) -> Void
    let onToggleMenuBar: (Bool) -> Void
    let onReconnect: (ProviderKind) -> Void
    let onFinish: () -> Void

    init(
        store: UsageStore,
        showsNotch: Bool,
        showsMenuBar: Bool,
        onToggleNotch: @escaping (Bool) -> Void,
        onToggleMenuBar: @escaping (Bool) -> Void,
        onReconnect: @escaping (ProviderKind) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.store = store
        self.onToggleNotch = onToggleNotch
        self.onToggleMenuBar = onToggleMenuBar
        self.onReconnect = onReconnect
        self.onFinish = onFinish
        _showsNotch = State(initialValue: showsNotch)
        _showsMenuBar = State(initialValue: showsMenuBar)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { item in
                        Capsule()
                            .fill(item == step ? Color.accentColor : Color.white.opacity(0.18))
                            .frame(width: item == step ? 24 : 8, height: 6)
                            .animation(.easeOut(duration: 0.2), value: step)
                    }
                }
                Spacer()
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 28)

            Group {
                switch step {
                case .welcome: welcomeStep
                case .providers: providersStep
                case .display: displayStep
                case .ready: readyStep
                }
            }
            .id(step)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack {
                Button("Skip") { onFinish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .cursor(.pointingHand)

                Spacer()

                if step != .welcome {
                    Button("Back") { move(to: step.rawValue - 1) }
                        .buttonStyle(.bordered)
                        .cursor(.pointingHand)
                }

                Button(step == .ready ? "Start using Metria" : "Continue") {
                    if step == .ready {
                        onFinish()
                    } else {
                        move(to: step.rawValue + 1)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .cursor(.pointingHand)
            }
            .padding(.top, 24)
        }
        .padding(32)
        .frame(width: 560, height: 620)
        .background(Color.black)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onChange(of: showsNotch) { onToggleNotch($0) }
        .onChange(of: showsMenuBar) { onToggleMenuBar($0) }
        .task(id: step) {
            guard step == .providers else { return }
            providerCheckTimedOut = false
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            providerCheckTimedOut = true
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)
            if let image = MetriaResources.bundle.url(forResource: "metria-mascot", withExtension: "png")
                .flatMap(NSImage.init(contentsOf:))
            {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .offset(y: mascotIsFloating && !reduceMotion ? -6 : 0)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 2).repeatForever(autoreverses: true),
                        value: mascotIsFloating
                    )
                    .onAppear { mascotIsFloating = true }
            } else {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 74, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            Text("Metria AI")
                .font(.title2.weight(.semibold))
            Text("Metria tracks your AI coding usage across Claude, Codex, OpenCode Go, Cursor, and Antigravity, right from your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var providersStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Connect your providers", subtitle: "Metria looks for credentials already stored on this Mac. Nothing is uploaded or copied.")
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(ProviderKind.allCases) { kind in
                        ProviderOnboardingRow(
                            kind: kind,
                            isAvailable: store.isProviderAvailable(kind),
                            isDetected: isProviderDetected(kind),
                            isChecking: kind == .cursor && !providerCheckTimedOut,
                            isEnabled: store.enabledProviderKinds.contains(kind),
                            accountLabel: store.providers.first(where: { $0.kind == kind })?.accountLabel,
                            setupHint: store.setupHint(for: kind),
                            onToggle: { store.setProviderEnabled(kind, isEnabled: $0) },
                            onReconnect: {
                                store.setProviderEnabled(kind, isEnabled: true)
                                onReconnect(kind)
                            }
                        )
                    }
                }
            }
            Text("You can connect more providers later in Settings > Providers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func isProviderDetected(_ kind: ProviderKind) -> Bool {
        if kind == .cursor {
            // A rate-limited or transiently-failing Cursor session still has real data —
            // only the total absence of usage windows means there's no valid session yet.
            return store.providers.contains { $0.kind == kind && !$0.windows.isEmpty }
        }
        return store.isProviderAvailable(kind)
    }

    private var displayStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("Choose where to see Metria", subtitle: "You can change these choices anytime in General settings.")
            VStack(spacing: 12) {
                DisplayChoice(
                    title: "Menu bar",
                    subtitle: "See a compact usage summary beside your other menu bar items.",
                    symbol: "menubar.rectangle",
                    isOn: $showsMenuBar
                )
                DisplayChoice(
                    title: "Side notch",
                    subtitle: "Keep a provider rail at the edge of your screen and expand it on hover.",
                    symbol: "rectangle.portrait.lefthalf.filled",
                    isOn: $showsNotch
                )
            }
            Text("At least one surface must remain enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var readyStep: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("Metria is ready")
                .font(.title2.weight(.semibold))
            Text("Hover the side notch for a quick view, or click the menu bar item for the full dashboard. Metria will refresh your usage automatically.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func stepHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func move(to rawValue: Int) {
        guard let nextStep = Step(rawValue: rawValue) else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
            step = nextStep
        }
    }
}

private struct ProviderOnboardingRow: View {
    let kind: ProviderKind
    let isAvailable: Bool
    let isDetected: Bool
    let isChecking: Bool
    let isEnabled: Bool
    let accountLabel: String?
    let setupHint: String?
    let onToggle: (Bool) -> Void
    let onReconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProviderLogo(provider: kind, size: 28)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.rawValue).font(.headline)
                if let accountLabel {
                    Text(accountDescription(for: accountLabel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(
                    isDetected
                        ? "Local credentials detected"
                        : isAvailable && isChecking
                            ? "Checking local session..."
                            : (setupHint ?? "Sign in to make usage available.")
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                if !isDetected {
                    Button("Connect", action: onReconnect)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .cursor(.pointingHand)
                }
                Toggle(
                    "Show in notch",
                    isOn: Binding(get: { isDetected && isEnabled }, set: onToggle)
                )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!isDetected)
                    .help(
                        isDetected
                            ? "Show \(kind.rawValue) in the notch"
                            : "Connect \(kind.rawValue) before showing it in the notch"
                    )
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func accountDescription(for label: String) -> String {
        kind == .openCodeGo ? "API key: \(label)" : "Account: \(label)"
    }
}

private struct DisplayChoice: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 34)
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isOn ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isOn ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
        }
        .cursor(.pointingHand)
    }
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { hovering in
            if hovering { cursor.push() } else { NSCursor.pop() }
        }
    }
}
