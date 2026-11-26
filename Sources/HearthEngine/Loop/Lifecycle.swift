/// The host app's lifecycle as the engine needs it. The host sets it from its scene phase or app delegate.
public enum Lifecycle: Sendable, Hashable, CaseIterable {
    case active
    /// Visible but not frontmost (a sheet, Control Centre, the app switcher). No encoding.
    case inactive
    /// Not visible. No GPU work at all.
    case background
}

/// Whether a frame may be encoded (E-LIFE-1, pitfall 2.14).
///
/// Encoding happens only while `.active` and while the GPU has not been taken away (`notPermitted`,
/// `accessRevoked`). Entering `.background` asks for one `waitUntilScheduled` on the last committed buffer, so the
/// frame in flight reaches the GPU before the app is suspended. A revocation lasts until the next `.active`, and
/// only work submitted since the latest entry into `.active` can revoke: a buffer from before a suspension that
/// fails after the host came back (its completion races the scene-phase callback) is logged, not obeyed.
struct LifecycleGate: Sendable, Hashable {
    private(set) var state = Lifecycle.active
    private(set) var revoked = false
    /// Entries into `.active` so far; work is stamped with the one it was submitted in.
    private(set) var activation = 0

    var canEncode: Bool { state == .active && !revoked }

    /// Moves to `next`. Returns true when the caller must wait until the last committed buffer is scheduled.
    mutating func enter(_ next: Lifecycle) -> Bool {
        let entersBackground = next == .background && state != .background
        if next == .active && state != .active {
            activation += 1
        }
        state = next
        if next == .active {
            revoked = false
        }
        return entersBackground
    }

    /// The GPU refused work submitted during `activation`; no encoding until the next `.active`. A refusal of work
    /// from an earlier activation changes nothing.
    mutating func revoke(submittedIn activation: Int) {
        if activation == self.activation {
            revoked = true
        }
    }
}
