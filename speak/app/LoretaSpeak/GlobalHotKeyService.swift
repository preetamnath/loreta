import Carbon.HIToolbox
import Foundation

enum GlobalHotKeyError: LocalizedError {
    case installHandlerFailed(OSStatus)
    case registerFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .installHandlerFailed(let status):
            "Failed to install global hotkey handler: \(status)"
        case .registerFailed(let status):
            "Failed to register global hotkey: \(status)"
        }
    }
}

@MainActor
final class GlobalHotKeyService {
    private static weak var activeService: GlobalHotKeyService?
    private static let hotKeySignature = OSType(
        UInt32(UInt8(ascii: "L")) << 24
            | UInt32(UInt8(ascii: "S")) << 16
            | UInt32(UInt8(ascii: "P")) << 8
            | UInt32(UInt8(ascii: "K"))
    )
    private static let hotKeyID = UInt32(1)

    private let onPressed: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(onPressed: @escaping @MainActor () -> Void) {
        self.onPressed = onPressed
    }

    func start() throws {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            throw GlobalHotKeyError.installHandlerFailed(handlerStatus)
        }

        let eventHotKeyID = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: Self.hotKeyID
        )

        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            eventHotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            stop()
            throw GlobalHotKeyError.registerFailed(registerStatus)
        }

        Self.activeService = self
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        if Self.activeService === self {
            Self.activeService = nil
        }
    }

    private func handlePress() {
        onPressed()
    }

    private static let eventHandler: EventHandlerUPP = { _, event, _ in
        guard let event else { return OSStatus(eventNotHandledErr) }

        var eventHotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &eventHotKeyID
        )

        guard status == noErr,
              eventHotKeyID.signature == hotKeySignature,
              eventHotKeyID.id == hotKeyID
        else {
            return OSStatus(eventNotHandledErr)
        }

        Task { @MainActor in
            activeService?.handlePress()
        }

        return noErr
    }
}
