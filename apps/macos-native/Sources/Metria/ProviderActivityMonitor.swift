import Darwin
import Foundation
import MetriaCore

@MainActor
final class ProviderActivityMonitor: ObservableObject {
    @Published private(set) var activeProviderKinds: Set<ProviderKind> = []

    private var monitoringTask: Task<Void, Never>?

    func start() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                let activeProviders = await Task.detached {
                    Self.detectActiveProviders()
                }.value
                guard let self, !Task.isCancelled else { return }
                self.activeProviderKinds = activeProviders
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    nonisolated private static func detectActiveProviders() -> Set<ProviderKind> {
        let runningProcesses = runningProcessCommands()
        let candidateKinds = processNamesByProvider.compactMap { kind, processNames -> ProviderKind? in
            let hasMatchingProcess = runningProcesses.contains { command in
                processNames.contains { command.contains($0) }
            }
            return hasMatchingProcess ? kind : nil
        }
        guard !candidateKinds.isEmpty else { return [] }

        // Only the providers whose process is already running are worth a disk scan —
        // this keeps idle cycles (the common case) free of any filesystem traversal.
        return recentSessionProviders(for: Set(candidateKinds))
    }

    // Cursor is matched on its bundle path rather than on "cursor" alone: macOS ships a
    // `CursorUIViewService` text-input helper that runs whether or not Cursor is installed.
    nonisolated private static let processNamesByProvider: [ProviderKind: Set<String>] = [
        .claude: ["claude"],
        .codex: ["codex"],
        .openCodeGo: ["opencode"],
        .cursor: ["cursor.app"],
        // Antigravity is matched on its bundle path plus the CLI binary's path
        // suffix: a bare "agy" substring would be too loose, the same way a
        // bare "cursor" was for Cursor above.
        .antigravity: ["antigravity.app", "/agy"]
    ]

    // Cursor has no per-session files: its agent conversations live in the same
    // `globalStorage` SQLite database `CursorProvider` reads credentials from. Scanning the
    // directory rather than the database picks up `state.vscdb-wal`, which is where writes
    // land between checkpoints — the main file's mtime alone would lag well past the cutoff.
    // The directory sees no writes at all while Cursor merely sits open, so a recent mtime
    // means real activity and not just a running app.
    nonisolated private static let sessionDirectoriesByProvider: [ProviderKind: [String]] = [
        .claude: [".claude/projects"],
        .codex: [".codex/sessions"],
        .openCodeGo: [".local/share/opencode/storage"],
        .cursor: ["Library/Application Support/Cursor/User/globalStorage"],
        // Same reasoning as Cursor: agent activity lands in the globalStorage
        // database WAL, while a merely open IDE writes nothing.
        .antigravity: ["Library/Application Support/Antigravity/User/globalStorage"]
    ]

    /// Reads every process's full command line directly via `sysctl`, avoiding the cost
    /// of forking `/bin/ps` on every polling cycle.
    nonisolated private static func runningProcessCommands() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else { return [] }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        return processes.prefix(actualCount).compactMap { info -> String? in
            let pid = info.kp_proc.p_pid
            guard pid > 0, let arguments = processArguments(for: pid) else { return nil }
            return arguments.joined(separator: " ").lowercased()
        }
    }

    /// Retrieves a process's argv via `sysctl(KERN_PROCARGS2)`, the same mechanism `ps`
    /// itself uses, without spawning a subprocess.
    nonisolated private static func processArguments(for pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size >= MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var cursor = MemoryLayout<Int32>.size
        // Skip the executable path the kernel prepends, then the NUL padding after it.
        while cursor < size, buffer[cursor] != 0 { cursor += 1 }
        while cursor < size, buffer[cursor] == 0 { cursor += 1 }

        var arguments: [String] = []
        var remaining = argc
        var start = cursor
        var index = cursor
        while index < size, remaining > 0 {
            if buffer[index] == 0 {
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                remaining -= 1
                start = index + 1
            }
            index += 1
        }
        return arguments
    }

    nonisolated private static func recentSessionProviders(for candidates: Set<ProviderKind>) -> Set<ProviderKind> {
        let cutoff = Date().addingTimeInterval(-15)
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        var providers = Set<ProviderKind>()

        for kind in candidates {
            guard let paths = sessionDirectoriesByProvider[kind] else { continue }
            for path in paths {
                let directory = homeDirectory.appendingPathComponent(path)
                guard let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                let hasRecentFile = enumerator.lazy.compactMap { item -> Date? in
                    guard let url = item as? URL else { return nil }
                    return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                }.contains { date in
                    date >= cutoff
                }

                if hasRecentFile {
                    providers.insert(kind)
                    break
                }
            }
        }

        return providers
    }

    deinit {
        monitoringTask?.cancel()
    }
}
