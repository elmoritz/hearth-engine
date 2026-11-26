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
/// frame in flight reaches the GPU before the app is suspended. A revocation lasts until the next `.active`.
struct LifecycleGate: Sendable, Hashable {
    private(set) var state = Lifecycle.active
    private(set) var revoked = false

    var canEncode: Bool { state == .active && !revoked }

    /// Moves to `next`. Returns true when the caller must wait until the last committed buffer is scheduled.
    mutating func enter(_ next: Lifecycle) -> Bool {
        let entersBackground = next == .background && state != .background
        state = next
        if next == .active {
            revoked = false
        }
        return entersBackground
    }

    /// The GPU refused this app's work; no encoding until the next `.active`.
    mutating func revoke() {
        revoked = true
    }
}
