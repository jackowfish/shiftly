import AppKit
import Carbon.HIToolbox

// Carbon hot keys: WindowServer dispatches these even while Secure Input is
// held, unlike a CGEventTap.

let hotKeySignature = OSType(0x5348_4654)  // 'SHFT'
var activeBindings: [Binding] = []
var hotKeyRefs: [EventHotKeyRef?] = []
var eventHandler: EventHandlerRef?

func makeBindings() -> [Binding] {
    let arrows: [(UInt32, Direction, String)] = [
        (UInt32(kVK_LeftArrow), .left, "left"),
        (UInt32(kVK_RightArrow), .right, "right"),
        (UInt32(kVK_UpArrow), .up, "up"),
        (UInt32(kVK_DownArrow), .down, "down"),
    ]
    return Layer.allCases.flatMap { layer in
        arrows.filter { layer.directions.contains($0.1) }.map { keyCode, direction, name in
            Binding(keyCode: keyCode,
                    modifiers: Settings.shared.modifiers(for: layer),
                    layer: layer,
                    direction: direction,
                    label: "\(layer) \(name)")
        }
    }
}

func handleHotKey(_ callRef: EventHandlerCallRef?,
                  _ event: EventRef?,
                  _ context: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr, Int(hotKeyID.id) < activeBindings.count else { return status }

    let binding = activeBindings[Int(hotKeyID.id)]
    gestureEngine.handle(layer: binding.layer, direction: binding.direction, label: binding.label)
    return noErr
}

/// (Re)registers every hot key from current settings.
func installHotKeys() {
    if eventHandler == nil {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), handleHotKey, 1, &spec, nil, &eventHandler)
    }

    for ref in hotKeyRefs {
        if let ref { UnregisterEventHotKey(ref) }
    }
    hotKeyRefs.removeAll()
    activeBindings = makeBindings()

    for (index, binding) in activeBindings.enumerated() {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: hotKeySignature, id: UInt32(index))
        let status = RegisterEventHotKey(binding.keyCode,
                                         binding.modifiers,
                                         id,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        hotKeyRefs.append(ref)
        if status != noErr {
            log("FAILED to register \(binding.label) (OSStatus \(status)) - another app likely owns that combo")
        }
    }
    log("hot keys installed")
}
