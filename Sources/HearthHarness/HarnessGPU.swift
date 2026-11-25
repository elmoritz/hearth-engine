import Foundation
import HearthEngine
import Metal

/// The one place the harness asks for a Metal device, so "no device" is a value tests can inject (E-HAR-5).
public enum HarnessGPU {
    public enum Availability {
        case available(MTLDevice)
        case unavailable(reason: String)

        public var device: MTLDevice? {
            switch self {
            case .available(let device): device
            case .unavailable: nil
            }
        }

        public var isAvailable: Bool { device != nil }
    }

    /// Set to `1` to run as a machine without a Metal device (a hosted CI runner).
    public static let noGPUVariable = "HEARTH_NO_GPU"

    public static func probe(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        provider: () -> MTLDevice? = { MTLCreateSystemDefaultDevice() }
    ) -> Availability {
        if environment[noGPUVariable] == "1" {
            return .unavailable(reason: "\(noGPUVariable)=1")
        }
        guard let device = provider() else {
            return .unavailable(reason: "no Metal device")
        }
        return .available(device)
    }

    /// Whether this process has a device. GPU tests are enabled by this and report skipped without one.
    public static let isAvailable: Bool = probe().isAvailable

    /// A renderer on the probed device. Throws `EngineError.noDevice` when there is none.
    public static func makeRenderer(_ availability: Availability = probe()) throws(EngineError) -> OffscreenRenderer {
        try OffscreenRenderer(device: availability.device)
    }
}
