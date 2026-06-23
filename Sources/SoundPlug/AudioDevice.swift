import Foundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable, Equatable, Sendable {
    var id: AudioDeviceID { deviceID }
    let deviceID: AudioDeviceID
    let name: String
    let uid: String
    let isInput: Bool
    let isOutput: Bool
    
    static func getDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard sizeStatus == noErr else {
            print("Failed to get audio device list size: \(sizeStatus)")
            return []
        }
        
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        
        guard dataStatus == noErr else {
            print("Failed to get audio device IDs: \(dataStatus)")
            return []
        }
        
        return deviceIDs.compactMap { id -> AudioDevice? in
            guard let name = getDeviceName(deviceID: id),
                  let uid = getDeviceUID(deviceID: id) else {
                return nil
            }
            
            let inputChannels = getChannelCount(for: id, scope: kAudioObjectPropertyScopeInput)
            let outputChannels = getChannelCount(for: id, scope: kAudioObjectPropertyScopeOutput)
            
            guard inputChannels > 0 || outputChannels > 0 else {
                return nil
            }
            
            return AudioDevice(
                deviceID: id,
                name: name,
                uid: uid,
                isInput: inputChannels > 0,
                isOutput: outputChannels > 0
            )
        }
    }
    
    /// Retrieves the device name using the C-string property (kAudioDevicePropertyDeviceName)
    /// which avoids the tricky CFString memory management issues with the CFString variant.
    static func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var propertySize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize
        )
        guard sizeStatus == noErr, propertySize > 0 else { return nil }
        
        // kAudioObjectPropertyName returns a CFString
        // Use withUnsafeMutablePointer to get a stable typed pointer
        var name: CFString?
        propertySize = UInt32(MemoryLayout<CFString?>.size)
        
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &propertySize,
                ptr
            )
        }
        
        guard status == noErr, let cfName = name else { return nil }
        return cfName as String
    }
    
    /// Retrieves the device UID via CoreAudio.
    static func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var uid: CFString?
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &propertySize,
                ptr
            )
        }
        
        guard status == noErr, let cfUID = uid else { return nil }
        return cfUID as String
    }
    
    static func getChannelCount(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard sizeStatus == noErr, dataSize > 0 else {
            return 0
        }
        
        // Allocate using raw byte count — dataSize is in bytes, not in
        // units of AudioBufferList. The previous code used .allocate(capacity: Int(dataSize))
        // which over-allocated by MemoryLayout<AudioBufferList>.size factor.
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        
        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        
        let dataStatus = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            bufferListPointer
        )
        
        guard dataStatus == noErr else {
            return 0
        }
        
        var channels = 0
        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        for buffer in buffers {
            channels += Int(buffer.mNumberChannels)
        }
        
        return channels
    }
}
