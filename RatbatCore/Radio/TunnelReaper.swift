import Foundation
import os

/// Finds and reaps `cloudflared` processes this app leaked on a previous run.
///
/// Ratbat spawns `cloudflared` as a child. If the app dies without running
/// its termination hook — SIGKILL, a crash, a force-quit — the child is not
/// killed with it. The OS reparents it to launchd (PPID 1) and it keeps
/// running, still holding a tunnel connection and still proxying to
/// `localhost:<port>`. The next launch spawns another. Cloudflare treats
/// multiple connections to one tunnel as HA replicas and load-balances
/// across them, so nothing looks broken, which is exactly why this went
/// unnoticed: an orphan from a 10:17 restart was found still running nearly
/// eight hours later, at ~40 MB RSS, alongside the live one.
///
/// It stays harmless only by coincidence — every replica happens to point at
/// the same port. Change the broadcast port and a stale orphan proxies to a
/// dead one while Cloudflare still routes a share of traffic to it:
/// intermittent 502s that look exactly like an outage, while every check on
/// the box stays green.
///
/// A termination hook cannot be the whole answer, because SIGKILL is
/// uncatchable by construction. So the hook handles the ordinary exits and
/// this handles what escapes: on launch, before starting a tunnel of our
/// own, adopt-and-kill whatever the last run left behind.
public enum TunnelReaper {

    /// One row of the process table.
    public struct ProcessSnapshot: Sendable, Equatable {
        public let pid: Int32
        public let parentPID: Int32
        public let executablePath: String

        public init(pid: Int32, parentPID: Int32, executablePath: String) {
            self.pid = pid
            self.parentPID = parentPID
            self.executablePath = executablePath
        }
    }

    /// Which of `processes` are `cloudflared` instances we leaked.
    ///
    /// Deliberately three narrow conditions, because this function's output
    /// is fed to `kill`:
    ///
    /// 1. **Exact executable path match** against *our own bundle's* binary
    ///    — not a substring, not "contains cloudflared". The machine also
    ///    runs an unrelated `/opt/homebrew/bin/cloudflared` serving a
    ///    different service from a different config, and it is itself
    ///    PPID 1. A looser filter would kill someone else's tunnel. Path
    ///    equality is what keeps that impossible.
    /// 2. **PPID 1** — reparented, i.e. the parent that spawned it is gone.
    ///    A live instance's own child has *our* pid as its parent, never 1,
    ///    so this alone already excludes it.
    /// 3. **Not us, and not our child** — belt and braces on top of (2), so
    ///    the invariant is stated rather than inferred from process
    ///    accounting.
    ///
    /// A process must satisfy all three. Anything we are unsure about is
    /// left alone: failing to reap costs 40 MB, reaping the wrong thing
    /// takes a service off the air.
    public static func orphans(
        among processes: [ProcessSnapshot],
        bundledBinary: String,
        ownPID: Int32,
        ownChildPIDs: Set<Int32> = []
    ) -> [Int32] {
        processes.filter { proc in
            proc.executablePath == bundledBinary
                && proc.parentPID == 1
                && proc.pid != ownPID
                && proc.parentPID != ownPID
                && !ownChildPIDs.contains(proc.pid)
        }
        .map(\.pid)
    }

    /// Parse `ps -axo pid=,ppid=,comm=` output.
    ///
    /// `comm` is last on the line and is a path that may contain spaces, so
    /// the remainder of the line after the two numeric columns is the path
    /// — splitting on whitespace and taking field 3 would truncate
    /// `/Applications/My Radio.app/...`. Malformed lines are skipped rather
    /// than guessed at.
    public static func parseProcessTable(_ text: String) -> [ProcessSnapshot] {
        text.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            var rest = Substring(line)

            func nextField() -> Substring? {
                guard let sp = rest.firstIndex(of: " ") else { return nil }
                let field = rest[..<sp]
                rest = rest[rest.index(after: sp)...]
                    .drop(while: { $0 == " " })
                return field
            }

            guard let pidField = nextField(),
                  let ppidField = nextField(),
                  let pid = Int32(pidField),
                  let ppid = Int32(ppidField)
            else { return nil }

            let path = String(rest)
            guard !path.isEmpty else { return nil }
            return ProcessSnapshot(pid: pid, parentPID: ppid, executablePath: path)
        }
    }

    // MARK: - Live process table

    /// Snapshot the process table via `ps`. Returns `[]` on any failure —
    /// not being able to look is a reason to do nothing, never a reason to
    /// guess.
    public static func snapshotProcesses() -> [ProcessSnapshot] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parseProcessTable(text)
    }

    /// Reap orphans left by previous runs. Returns the pids signalled.
    ///
    /// `SIGTERM`, not `SIGKILL`: cloudflared handles it ("Initiating
    /// graceful shutdown due to signal terminated") and unregisters from the
    /// Cloudflare edge on the way out. Killing a replica outright leaves the
    /// edge briefly routing to something that is gone — a measured ~15-30s
    /// window of 502s before it re-routes. Asking politely avoids handing
    /// listeners an error on startup.
    @discardableResult
    public static func reapOrphans(
        bundledBinary: String,
        logger: Logger
    ) -> [Int32] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let found = orphans(
            among: snapshotProcesses(),
            bundledBinary: bundledBinary,
            ownPID: ownPID
        )
        guard !found.isEmpty else { return [] }
        for pid in found {
            let rc = kill(pid, SIGTERM)
            if rc == 0 {
                logger.notice(
                    "reaped orphaned cloudflared pid \(pid, privacy: .public) left by a previous run"
                )
            } else {
                // Already gone between snapshot and signal, or not ours to
                // signal. Either way there is nothing further to do.
                logger.info(
                    "could not signal pid \(pid, privacy: .public): errno \(errno, privacy: .public)"
                )
            }
        }
        return found
    }
}
