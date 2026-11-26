import Foundation

/// Low Power Mode and thermal state, observed through their notifications (`research/performance-and-power.md` 2).
@MainActor
final class SystemConditions {
    private(set) var lowPower: Bool
    private(set) var thermal: ThermalLevel
    var onChange: ((Bool, ThermalLevel) -> Void)?

    private let center: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    init(processInfo: ProcessInfo = .processInfo, center: NotificationCenter = .default) {
        self.center = center
        lowPower = processInfo.isLowPowerModeEnabled
        thermal = ThermalLevel(processInfo.thermalState)
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(from: .processInfo) }
            })
        }
    }

    func refresh(from processInfo: ProcessInfo) {
        update(lowPower: processInfo.isLowPowerModeEnabled, thermal: ThermalLevel(processInfo.thermalState))
    }

    func update(lowPower: Bool, thermal: ThermalLevel) {
        self.lowPower = lowPower
        self.thermal = thermal
        onChange?(lowPower, thermal)
    }

    func invalidate() {
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
    }
}

extension ThermalLevel {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }
}
