import Foundation
import AVFoundation

@MainActor
final class PluginManager: Sendable {
    static let shared = PluginManager()
    
    private init() {}
    
    func scanAvailablePlugins() -> [AVAudioUnitComponent] {
        let types = [
            kAudioUnitType_Effect,
            kAudioUnitType_MusicEffect
        ]
        
        var allComponents: [AVAudioUnitComponent] = []
        for type in types {
            let desc = AudioComponentDescription(
                componentType: type,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            let components = AVAudioUnitComponentManager.shared().components(matching: desc)
            allComponents.append(contentsOf: components)
        }
        
        return allComponents.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
    
    /// Instantiates an audio unit from a component descriptor.
    func instantiatePlugin(component: AVAudioUnitComponent, completion: @MainActor @escaping @Sendable (AVAudioUnit?, (any Error)?) -> Void) {
        let desc = component.audioComponentDescription
        AVAudioUnit.instantiate(with: desc, options: []) { audioUnit, error in
            // Use nonisolated(unsafe) to move the AVAudioUnit across isolation.
            // This is safe because we immediately hand it off to the MainActor-isolated
            // AudioEngineManager and never access it from any other isolation domain.
            nonisolated(unsafe) let safeUnit = audioUnit
            let safeError = error
            Task { @MainActor in
                completion(safeUnit, safeError)
            }
        }
    }
}
