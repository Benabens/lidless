import Foundation
import IOKit.ps
import LidlessCore

/// Reads the power source and reports when it changes (plugged in, unplugged, battery level).
@MainActor
final class PowerMonitor {
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            // The source is scheduled on the main run loop.
            MainActor.assumeIsolated { monitor.onChange?() }
        }, context)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        source = nil
    }

    static func currentState() -> PowerState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerState(isOnAC: true, batteryPercent: nil)
        }
        let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        let isOnAC = providing != kIOPSBatteryPowerValue

        var batteryPercent: Int?
        let sources = (IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            batteryPercent = Int((Double(current) / Double(maximum) * 100).rounded())
        }
        return PowerState(isOnAC: isOnAC, batteryPercent: batteryPercent)
    }
}
