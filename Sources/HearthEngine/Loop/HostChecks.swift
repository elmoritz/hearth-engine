import Foundation

/// The kind of device the host runs on, as far as frame pacing cares.
public enum DeviceIdiom: Sendable, Hashable, CaseIterable {
    case phone
    case pad
    case mac

    /// This process's device: the Mac, or an iPhone or iPad by its model identifier (the Simulator's included).
    public static var current: DeviceIdiom {
        #if os(macOS)
            .mac
        #else
            idiom(model: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine())
        #endif
    }

    /// `iPhone15,2` is a phone, `iPad13,4` a pad; anything else is treated as a Mac (no plist rule applies).
    static func idiom(model: String) -> DeviceIdiom {
        if model.hasPrefix("iPhone") { return .phone }
        if model.hasPrefix("iPad") { return .pad }
        return .mac
    }

    #if !os(macOS)
        private static func machine() -> String {
            var size = 0
            sysctlbyname("hw.machine", nil, &size, nil, 0)
            var bytes = [CChar](repeating: 0, count: Swift.max(size, 1))
            sysctlbyname("hw.machine", &bytes, &size, nil, 0)
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    #endif
}

/// A condition the engine reports and never acts on alone.
public enum EngineWarning: Sendable, Hashable {
    /// The host allows above 60 Hz on an iPhone, whose Info.plist lacks `CADisableMinimumFrameDurationOnPhone`, so
    /// the system holds it at 60 (E-PLIST-1).
    case highRateWithoutPlistKey
}

/// Checks of the host's integration, run once at startup (E-PLIST-1).
enum HostChecks {
    static let minimumFrameDurationKey = "CADisableMinimumFrameDurationOnPhone"

    /// The warnings for a host with this Info.plist on this device. Only an iPhone asking for a high rate needs the
    /// key, and only the Boolean `true` counts as set.
    static func startupWarnings(info: [String: Any]?, idiom: DeviceIdiom, highRateAllowed: Bool) -> [EngineWarning] {
        guard idiom == .phone, highRateAllowed else { return [] }
        let declared = info?[minimumFrameDurationKey] as? Bool == true
        return declared ? [] : [.highRateWithoutPlistKey]
    }
}
