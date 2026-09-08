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
    @State private var displaySurface: DisplaySurface
    @State private var mascotIsFloating = false
    @State private var providerCheckTimedOut = false

    let onSelectDisplaySurface: (DisplaySurface) -> Void
    let onReconnect: (ProviderKind) -> Void
    let onFinish: () -> Void

    init(
        store: UsageStore,
        showsNotch: Bool,
        showsMenuBar: Bool,
        onSelectDisplaySurface: @escaping (DisplaySurface) -> Void,
        onReconnect: @escaping (ProviderKind) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.store = store
        self.onSelectDisplaySurface = onSelectDisplaySurface
        self.onReconnect = onReconnect
        self.onFinish = onFinish
        _displaySurface = State(initialValue: DisplaySurface(showsNotch: showsNotch, showsMenuBar: showsMenuBar))
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
        .onChange(of: displaySurface) { onSelectDisplaySurface($0) }
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
                    ForEach(store.registeredProviderIDs, id: \.self) { id in
                        ProviderOnboardingRow(
                            id: id,
                            isAvailable: store.isProviderAvailable(id),
                            isDetected: isProviderDetected(id),
                            isChecking: id.kind == .cursor && !providerCheckTimedOut,
                            isEnabled: store.enabledProviderIDs.contains(id),
                            accountLabel: store.providers.first(where: { $0.id == id })?.accountLabel,
                            setupHint: store.setupHint(for: id),
                            onToggle: { store.setProviderEnabled(id, isEnabled: $0) },
                            onReconnect: {
                                store.setProviderEnabled(id, isEnabled: true)
                                onReconnect(id.kind)
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

    private func isProviderDetected(_ id: ProviderID) -> Bool {
        if id.kind == .cursor {
            // A rate-limited or transiently-failing Cursor session still has real data —
            // only the total absence of usage windows means there's no valid session yet.
            return store.providers.contains { $0.id == id && !$0.windows.isEmpty }
        }
        return store.isProviderAvailable(id)
    }

    private var displayStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("Choose where to see Metria", subtitle: "You can change these choices anytime in General settings.")
            FlexSegmentedControl(
                options: DisplaySurface.allCases,
                title: { $0.title },
                symbolName: { $0.systemImage },
                selection: $displaySurface
            )
            .frame(maxWidth: .infinity, minHeight: 24)
            Text("Choose Menu for the menu bar, Notch for the side notch, or Both to show both surfaces.")
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
    let id: ProviderID
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
            ProviderLogo(provider: id.kind, size: 28)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(id.displayName).font(.headline)
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
                            ? "Show \(id.displayName) in the notch"
                            : "Connect \(id.displayName) before showing it in the notch"
                    )
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func accountDescription(for label: String) -> String {
        id.kind == .openCodeGo ? "API key: \(label)" : "Account: \(label)"
    }
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { hovering in
            if hovering { cursor.push() } else { NSCursor.pop() }
        }
    }
}
