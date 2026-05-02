import CoreAudio
import Foundation
import OSLog

enum SystemOutputSuppressionError: LocalizedError {
    case unsupportedCurrentRoute
    case coreAudioFailure(context: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedCurrentRoute:
            "Loreta Speak could not silence the current output device, so background audio may stay audible while recording."
        case .coreAudioFailure(let context, _):
            "Loreta Speak hit a macOS audio-device error while \(context)."
        }
    }
}

final class SystemOutputSuppressionService {
    private static let logger = Logger(subsystem: "com.loreta.speak", category: "SystemOutputSuppression")

    private enum SuppressionStrategy {
        case mute(previousValue: UInt32)
        case masterVolume(previousValue: Float32)
        case channelVolumes(previousValues: [UInt32: Float32])
    }

    private struct DeviceSuppressionSnapshot {
        let deviceID: AudioObjectID
        let strategy: SuppressionStrategy
    }

    private struct ActiveSuppression {
        var snapshotsByDevice: [AudioObjectID: DeviceSuppressionSnapshot]
        let listener: AudioObjectPropertyListenerBlock
    }

    private let listenerQueue = DispatchQueue(label: "com.loreta.speak.output-suppression")
    private var activeSuppression: ActiveSuppression?

    func beginSuppression() throws {
        try listenerQueue.sync {
            try beginSuppressionLocked()
        }
    }

    func endSuppression() throws {
        try listenerQueue.sync {
            try endSuppressionLocked()
        }
    }

    private func beginSuppressionLocked() throws {
        guard activeSuppression == nil else { return }

        let targetDeviceIDs = try currentTargetDeviceIDs()
        var snapshotsByDevice: [AudioObjectID: DeviceSuppressionSnapshot] = [:]

        do {
            for deviceID in targetDeviceIDs {
                snapshotsByDevice[deviceID] = try suppressDevice(deviceID)
            }

            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleRouteChange()
            }

            try registerRouteListeners(listener)
            activeSuppression = ActiveSuppression(
                snapshotsByDevice: snapshotsByDevice,
                listener: listener
            )
        } catch {
            for snapshot in snapshotsByDevice.values {
                try? restore(snapshot)
            }
            throw error
        }
    }

    private func endSuppressionLocked() throws {
        guard let activeSuppression else { return }

        unregisterRouteListeners(activeSuppression.listener)
        self.activeSuppression = nil

        var firstError: Error?
        for snapshot in activeSuppression.snapshotsByDevice.values {
            do {
                try restore(snapshot)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private func handleRouteChange() {
        guard var activeSuppression else { return }

        do {
            let currentDeviceIDs = try currentTargetDeviceIDs()
            for deviceID in currentDeviceIDs where activeSuppression.snapshotsByDevice[deviceID] == nil {
                activeSuppression.snapshotsByDevice[deviceID] = try suppressDevice(deviceID)
            }
            self.activeSuppression = activeSuppression
        } catch {
            Self.logger.error("Output route change suppression failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func registerRouteListeners(_ listener: @escaping AudioObjectPropertyListenerBlock) throws {
        var defaultOutputAddress = propertyAddress(
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        try setUpListener(for: AudioObjectID(kAudioObjectSystemObject), address: &defaultOutputAddress, listener: listener)

        var defaultSystemOutputAddress = propertyAddress(
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        try setUpListener(for: AudioObjectID(kAudioObjectSystemObject), address: &defaultSystemOutputAddress, listener: listener)
    }

    private func unregisterRouteListeners(_ listener: @escaping AudioObjectPropertyListenerBlock) {
        var defaultOutputAddress = propertyAddress(
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            listenerQueue,
            listener
        )

        var defaultSystemOutputAddress = propertyAddress(
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultSystemOutputAddress,
            listenerQueue,
            listener
        )
    }

    private func setUpListener(
        for objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) throws {
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, listenerQueue, listener)
        guard status == kAudioHardwareNoError else {
            throw SystemOutputSuppressionError.coreAudioFailure(
                context: "watching output device changes",
                status: status
            )
        }
    }

    private func currentTargetDeviceIDs() throws -> [AudioObjectID] {
        let defaultOutputDeviceID = try defaultDeviceID(for: kAudioHardwarePropertyDefaultOutputDevice)
        let defaultSystemOutputDeviceID = try defaultDeviceID(for: kAudioHardwarePropertyDefaultSystemOutputDevice)

        var deviceIDs: [AudioObjectID] = []
        for deviceID in [defaultOutputDeviceID, defaultSystemOutputDeviceID] where deviceID != kAudioObjectUnknown {
            if !deviceIDs.contains(deviceID) {
                deviceIDs.append(deviceID)
            }
        }
        return deviceIDs
    }

    private func defaultDeviceID(for selector: AudioObjectPropertySelector) throws -> AudioObjectID {
        var address = propertyAddress(
            selector: selector,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        return try getUInt32(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: &address
        )
    }

    private func suppressDevice(_ deviceID: AudioObjectID) throws -> DeviceSuppressionSnapshot {
        guard try isAlive(deviceID) else {
            throw SystemOutputSuppressionError.unsupportedCurrentRoute
        }

        if let muteSnapshot = try suppressWithMute(deviceID) {
            return muteSnapshot
        }

        if let volumeSnapshot = try suppressWithVolume(deviceID) {
            return volumeSnapshot
        }

        throw SystemOutputSuppressionError.unsupportedCurrentRoute
    }

    private func suppressWithMute(_ deviceID: AudioObjectID) throws -> DeviceSuppressionSnapshot? {
        var address = propertyAddress(
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        )

        guard try propertyIsSettable(objectID: deviceID, address: &address) else {
            return nil
        }

        let previousValue = try getUInt32(objectID: deviceID, address: &address)
        try setUInt32(1, objectID: deviceID, address: &address)
        return DeviceSuppressionSnapshot(
            deviceID: deviceID,
            strategy: .mute(previousValue: previousValue)
        )
    }

    private func suppressWithVolume(_ deviceID: AudioObjectID) throws -> DeviceSuppressionSnapshot? {
        var masterAddress = propertyAddress(
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        )

        if try propertyIsSettable(objectID: deviceID, address: &masterAddress) {
            let previousValue = try getFloat32(objectID: deviceID, address: &masterAddress)
            try setFloat32(0, objectID: deviceID, address: &masterAddress)
            return DeviceSuppressionSnapshot(
                deviceID: deviceID,
                strategy: .masterVolume(previousValue: previousValue)
            )
        }

        let channels = try outputChannels(for: deviceID)
        var previousValues: [UInt32: Float32] = [:]

        for channel in channels {
            var channelAddress = propertyAddress(
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: channel
            )

            guard try propertyIsSettable(objectID: deviceID, address: &channelAddress) else {
                continue
            }

            let previousValue = try getFloat32(objectID: deviceID, address: &channelAddress)
            try setFloat32(0, objectID: deviceID, address: &channelAddress)
            previousValues[channel] = previousValue
        }

        guard !previousValues.isEmpty else {
            return nil
        }

        return DeviceSuppressionSnapshot(
            deviceID: deviceID,
            strategy: .channelVolumes(previousValues: previousValues)
        )
    }

    private func restore(_ snapshot: DeviceSuppressionSnapshot) throws {
        guard try isAlive(snapshot.deviceID) else { return }

        switch snapshot.strategy {
        case .mute(let previousValue):
            var address = propertyAddress(
                selector: kAudioDevicePropertyMute,
                scope: kAudioDevicePropertyScopeOutput,
                element: kAudioObjectPropertyElementMain
            )
            guard try propertyIsSettable(objectID: snapshot.deviceID, address: &address) else { return }
            let currentValue = try getUInt32(objectID: snapshot.deviceID, address: &address)
            guard currentValue == 1 else { return }
            try setUInt32(previousValue, objectID: snapshot.deviceID, address: &address)

        case .masterVolume(let previousValue):
            var address = propertyAddress(
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: kAudioObjectPropertyElementMain
            )
            guard try propertyIsSettable(objectID: snapshot.deviceID, address: &address) else { return }
            let currentValue = try getFloat32(objectID: snapshot.deviceID, address: &address)
            guard abs(currentValue) < 0.0001 else { return }
            try setFloat32(previousValue, objectID: snapshot.deviceID, address: &address)

        case .channelVolumes(let previousValues):
            for (channel, previousValue) in previousValues {
                var address = propertyAddress(
                    selector: kAudioDevicePropertyVolumeScalar,
                    scope: kAudioDevicePropertyScopeOutput,
                    element: channel
                )
                guard try propertyIsSettable(objectID: snapshot.deviceID, address: &address) else { continue }
                let currentValue = try getFloat32(objectID: snapshot.deviceID, address: &address)
                guard abs(currentValue) < 0.0001 else { continue }
                try setFloat32(previousValue, objectID: snapshot.deviceID, address: &address)
            }
        }
    }

    private func isAlive(_ deviceID: AudioObjectID) throws -> Bool {
        var address = propertyAddress(
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        return try getUInt32(objectID: deviceID, address: &address) != 0
    }

    private func outputChannels(for deviceID: AudioObjectID) throws -> [UInt32] {
        var channels = Set<UInt32>()

        var preferredStereoAddress = propertyAddress(
            selector: kAudioDevicePropertyPreferredChannelsForStereo,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        )
        if hasProperty(objectID: deviceID, address: &preferredStereoAddress) {
            let preferredChannels = try getStereoChannels(objectID: deviceID, address: &preferredStereoAddress)
            preferredChannels.forEach { channels.insert($0) }
        }

        var streamConfigurationAddress = propertyAddress(
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        )
        if hasProperty(objectID: deviceID, address: &streamConfigurationAddress) {
            let streamChannelCount = try getOutputChannelCount(objectID: deviceID, address: &streamConfigurationAddress)
            if streamChannelCount > 0 {
                for channel in 1...streamChannelCount {
                    channels.insert(channel)
                }
            }
        }

        return channels.sorted()
    }

    private func getOutputChannelCount(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) throws -> UInt32 {
        let dataSize = try getPropertyDataSize(objectID: objectID, address: &address)
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        var ioDataSize = dataSize
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &ioDataSize,
            rawPointer
        )
        guard status == kAudioHardwareNoError else {
            throw SystemOutputSuppressionError.coreAudioFailure(
                context: "reading output channel configuration",
                status: status
            )
        }

        let audioBufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let audioBuffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
        return audioBuffers.reduce(0) { partialResult, buffer in
            partialResult + buffer.mNumberChannels
        }
    }

    private func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    private func hasProperty(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> Bool {
        AudioObjectHasProperty(objectID, &address)
    }

    private func propertyIsSettable(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) throws -> Bool {
        guard hasProperty(objectID: objectID, address: &address) else { return false }

        var isSettable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(objectID, &address, &isSettable)
        guard status == kAudioHardwareNoError else {
            throw SystemOutputSuppressionError.coreAudioFailure(
                context: "checking whether an output control is settable",
                status: status
            )
        }
        return isSettable.boolValue
    }

    private func getPropertyDataSize(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) throws -> UInt32 {
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard status == kAudioHardwareNoError else {
            throw SystemOutputSuppressionError.coreAudioFailure(
                context: "querying output control size",
                status: status
            )
        }
        return dataSize
    }

    private func getUInt32(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) throws -> UInt32 {
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == kAudioHardwareNoError else {
            throw SystemOutputSuppressionError.coreAudioFailure(
                context: "reading an output control",
                status: status
            )
        }
        return value
    }

    private func getFloat32(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) throws -> Float32 {
        var value: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == kAudioHardwareNoError else {
            throw SystemOutputSuppressionError.coreAudioFailure(
                context: "reading device output volume",
                status: status
            )
        }
        return value
    }

    private func getStereoChannels(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) throws -> [UInt32] {
        var values = [UInt32](repeating: 0, count: 2)
        var dataSize = UInt32(MemoryLayout<UInt32>.size * values.count)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &values)
        guard status == kAudioHardwareNoError else {
            throw SystemOutputSuppressionError.coreAudioFailure(
                context: "reading preferred stereo channels",
                status: status
            )
        }
        return values.filter { $0 > 0 }
    }

    private func setUInt32(
        _ value: UInt32,
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) throws {
        var mutableValue = value
        let status = AudioObjectSetPropertyData(
            objectID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutableValue
        )
        guard status == kAudioHardwareNoError else {
            throw SystemOutputSuppressionError.coreAudioFailure(
                context: "silencing background audio",
                status: status
            )
        }
    }

    private func setFloat32(
        _ value: Float32,
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) throws {
        var mutableValue = value
        let status = AudioObjectSetPropertyData(
            objectID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &mutableValue
        )
        guard status == kAudioHardwareNoError else {
            throw SystemOutputSuppressionError.coreAudioFailure(
                context: value == 0 ? "silencing background audio" : "restoring background audio",
                status: status
            )
        }
    }
}
