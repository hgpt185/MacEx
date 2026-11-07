import AppKit
import Combine
import IOKit.ps

/// The run-loop source owns its callback context until invalidated; there is no polling timer.
private final class PowerSourceMonitor: @unchecked Sendable {
    let changed: @Sendable () -> Void
    private var source: CFRunLoopSource?
    init(changed: @escaping @Sendable () -> Void) {
        self.changed = changed
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue().changed()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return type as String == kIOPSBatteryPowerValue
    }
    deinit { if let source { CFRunLoopSourceInvalidate(source) } }
}

@MainActor final class ApplicationActivity {
    private weak var window: NSWindow?
    private weak var library: LibraryModel?
    private var observations = Set<AnyCancellable>()
    private var power: PowerSourceMonitor?
    init(window: NSWindow, library: LibraryModel) {
        self.window = window; self.library = library
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in self?.update() }.store(in: &observations)
        }
        power = PowerSourceMonitor { [weak self] in Task { @MainActor [weak self] in self?.update() } }
        update()
    }
    func update() {
        guard let window, let library else { return }
        let active = NSApp.isActive && !NSApp.isHidden && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        library.setActivity(active: active, onBattery: PowerSourceMonitor.onBattery)
    }
}
