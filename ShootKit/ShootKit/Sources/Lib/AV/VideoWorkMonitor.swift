import Foundation

// Ecamm: Safety accounting only, never a frame scheduler. All callers are in the helper,
// not Ecamm's render thread. Track queued work through its real completion, including
// retired codecs, so a responsive Network queue cannot hide a stuck VideoToolbox queue.
final class VideoWorkMonitor {
    enum Kind { case encode, decode, send, teardown }
    private struct Work {
        let kind: Kind; let bytes: Int; let started: TimeInterval; let owner: ObjectIdentifier?
        var submitted = false
    }
    private let lock = NSLock()
    private var pending: [UInt: Work] = [:]
    private var nextToken: UInt = 0
    private var teardownOverflow = false
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func begin(_ kind: Kind, bytes: Int = 0, owner: AnyObject? = nil) -> UInt? {
        lock.lock(); defer { lock.unlock() }
        let work = pending.values.filter { $0.kind == kind }
        // These generous ceilings tolerate ordinary keyframe bursts. They are not pacing targets.
        let countLimit = kind == .send ? 120 : (kind == .teardown ? 16 : 32)
        let byteLimit = kind == .send ? 8 * 1024 * 1024 : 16 * 1024 * 1024
        guard bytes >= 0, bytes <= byteLimit, work.count < countLimit,
              work.reduce(0, { $0 + $1.bytes }) <= byteLimit - bytes else {
            // Too many retired codecs means teardown itself is stuck; the helper must exit.
            if kind == .teardown { teardownOverflow = true }
            return nil
        }
        nextToken &+= 1
        if nextToken == 0 { nextToken = 1 } // Zero is reserved for a nil C callback refcon.
        pending[nextToken] = Work(kind: kind, bytes: bytes, started: now(), owner: owner.map(ObjectIdentifier.init))
        return nextToken
    }

    func finish(_ token: UInt) {
        lock.lock(); defer { lock.unlock() }
        // VideoToolbox may both report a dropped submission and call its callback; finish is idempotent.
        pending.removeValue(forKey: token)
    }

    func submitted(_ token: UInt) {
        lock.lock(); defer { lock.unlock() }
        // Parameter replacement retires submitted frames, not inputs queued for the new parameters.
        pending[token]?.submitted = true
    }

    func finishInvalidatedCodec(_ owner: AnyObject, includingQueued: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        // Invalidation may discard frames without callbacks. Clear them only AFTER it returns;
        // a hung invalidation must remain visible to the watchdog across reconnections.
        pending = pending.filter {
            $0.value.owner != ObjectIdentifier(owner) || (!includingQueued && !$0.value.submitted)
        }
    }

    var hasPendingWork: Bool {
        lock.lock(); defer { lock.unlock() }
        return teardownOverflow || !pending.isEmpty
    }

    var hasStalledWork: Bool {
        lock.lock(); defer { lock.unlock() }
        // Idle streams never time out. Only work actually queued/submitted can become overdue.
        let time = now()
        return teardownOverflow || pending.values.contains { time - $0.started > 5 }
    }
}
