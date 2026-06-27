import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey registered through Carbon's `RegisterEventHotKey`.
/// Fires `onPress` on the main actor from any application.
///
/// Carbon is used (rather than a Cocoa monitor) because it delivers the key event
/// globally without requiring Accessibility permission, and without the key being
/// swallowed by the frontmost app. The C event callback can't capture Swift context,
/// so we route by hotkey id through a small registry.
///
/// Everything here is main-actor-isolated: Carbon hotkey events are delivered on the
/// main run loop, and we want `onPress` to run on the main actor (it drives AppKit).
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32
    private let onPress: () -> Void

    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    // Storage for the single installed handler (so it isn't deallocated).
    private static var eventHandler: EventHandlerRef?

    /// - Parameters:
    ///   - keyCode: a Carbon virtual key code (e.g. `kVK_Space`).
    ///   - modifiers: Carbon modifier mask (e.g. `cmdKey | optionKey`).
    init(keyCode: UInt32, modifiers: UInt32, onPress: @escaping () -> Void) {
        self.id = Self.nextID
        Self.nextID += 1
        self.onPress = onPress

        Self.installDispatcherIfNeeded()
        Self.registry[id] = self

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("Chingu: failed to register global hotkey (status \(status)).")
        }
    }

    // No `deinit` cleanup: `registry` holds a strong reference to every live
    // `GlobalHotKey`, and Chingu's single hotkey is created once at launch and lives
    // for the whole process, so it is never deallocated. (If hotkeys ever became
    // dynamic, add an explicit `unregister()` that calls `UnregisterEventHotKey` and
    // clears the registry entry from the main actor.)

    // 'CHGU' as an OSType signature for our hotkeys.
    private static let signature: OSType = {
        let chars = Array("CHGU".utf8)
        return (OSType(chars[0]) << 24) | (OSType(chars[1]) << 16)
            | (OSType(chars[2]) << 8) | OSType(chars[3])
    }()

    private func fire() { onPress() }

    /// Installs the process-wide Carbon event handler once. It looks up the firing
    /// hotkey by id and invokes that instance's closure on the main actor.
    private static func installDispatcherIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var firedID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &firedID)
                guard status == noErr else { return status }

                // Carbon delivers this on the main run loop; hop onto the main actor
                // to touch the isolated registry and run the handler.
                let firedKey = firedID.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        GlobalHotKey.registry[firedKey]?.fire()
                    }
                }
                return noErr
            },
            1, &spec, nil, &eventHandler)
    }
}
