import Foundation
import AVFoundation
import Observation
import CoreAudio

/// Wrapper for an active audio unit plugin in the signal chain.
/// Marked @unchecked Sendable because AVAudioUnit (NSObject) is not Sendable,
/// but all access is confined to @MainActor through AudioEngineManager.
struct ActivePlugin: Identifiable, @unchecked Sendable {
    let id = UUID()
    let audioUnit: AVAudioUnit
}

@Observable
@MainActor
final class AudioEngineManager {
    static let shared = AudioEngineManager()
    
    var availableInputs: [AudioDevice] = []
    var availableOutputs: [AudioDevice] = []
    
    var selectedInputDevice: AudioDevice? {
        didSet {
            if isRouting {
                start()
            }
        }
    }
    
    var selectedOutputDevice: AudioDevice? {
        didSet {
            if isRouting {
                start()
            }
        }
    }
    
    var isRouting: Bool = false
    var hasPermission: Bool = false
    
    private(set) var activePlugins: [ActivePlugin] = []
    
    private var inputEngine = AVAudioEngine()
    private var outputEngine = AVAudioEngine()
    private let ringBuffer = AudioRingBuffer()
    private var sourceNode: AVAudioSourceNode?
    
    // Device change listener ID for cleanup.
    // These lifecycle management properties need nonisolated(unsafe) because
    // deinit is nonisolated and needs to clean them up. @ObservationIgnored
    // prevents the @Observable macro from synthesizing tracking code that
    // conflicts with the nonisolated modifier.
    @ObservationIgnored nonisolated(unsafe) private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored nonisolated(unsafe) private var inputConfigObserver: (any NSObjectProtocol)?
    @ObservationIgnored nonisolated(unsafe) private var outputConfigObserver: (any NSObjectProtocol)?
    
    private init() {
        self.sourceNode = createSourceNode(ringBuffer: ringBuffer)
        setupDeviceChangeListener()
        setupConfigurationChangeObservers()
    }
    
    deinit {
        // deinit is nonisolated, so we inline the cleanup directly
        // rather than calling @MainActor-isolated methods.
        if let block = deviceListenerBlock {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                DispatchQueue.main,
                block
            )
        }
        if let observer = inputConfigObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = outputConfigObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    nonisolated private func createSourceNode(ringBuffer: AudioRingBuffer) -> AVAudioSourceNode {
        return AVAudioSourceNode { (isSilence, timestamp, frameCount, audioBufferList) -> OSStatus in
            ringBuffer.read(into: audioBufferList, count: Int(frameCount))
            isSilence.pointee = false
            return noErr
        }
    }
    
    // MARK: - Permissions
    
    func checkPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        self.hasPermission = (status == .authorized)
    }
    
    func requestPermissions(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.hasPermission = granted
                    completion(granted)
                }
            }
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.hasPermission = granted
                    completion(granted)
                }
            }
        }
    }
    
    // MARK: - Device Management
    
    func refreshDevices() {
        let devices = AudioDevice.getDevices()
        availableInputs = devices.filter { $0.isInput }
        availableOutputs = devices.filter { $0.isOutput }
        
        // Validate that currently selected devices still exist
        if let selected = selectedInputDevice,
           !availableInputs.contains(where: { $0.deviceID == selected.deviceID }) {
            selectedInputDevice = nil
        }
        if let selected = selectedOutputDevice,
           !availableOutputs.contains(where: { $0.deviceID == selected.deviceID }) {
            selectedOutputDevice = nil
        }
        
        if selectedInputDevice == nil {
            selectedInputDevice = availableInputs.first(where: { $0.name.lowercased().contains("blackhole") })
                ?? availableInputs.first(where: { $0.name.lowercased().contains("mic") })
                ?? availableInputs.first
        }
        
        if selectedOutputDevice == nil {
            selectedOutputDevice = availableOutputs.first(where: { $0.name.lowercased().contains("speaker") })
                ?? availableOutputs.first(where: { $0.name.lowercased().contains("headphones") })
                ?? availableOutputs.first
        }
    }
    
    // MARK: - Engine Lifecycle
    
    func start() {
        guard hasPermission else {
            print("No audio input permission")
            return
        }
        
        guard let inputDevice = selectedInputDevice, let outputDevice = selectedOutputDevice else {
            print("Devices not selected")
            return
        }
        
        // Full teardown before reconfiguring
        stop()
        ringBuffer.clear()
        
        // --- Input Engine Setup ---
        let inputNode = inputEngine.inputNode
        let isInputDeviceSet = setDeviceID(inputDevice.deviceID, for: inputNode)
        guard isInputDeviceSet else {
            print("Failed to set input device")
            return
        }
        
        // Use the hardware's actual format for the tap — this ensures we match
        // whatever sample rate / channel count the device provides.
        let inputHWFormat = inputNode.inputFormat(forBus: 0)
        guard inputHWFormat.sampleRate > 0, inputHWFormat.channelCount > 0 else {
            print("Invalid input format: \(inputHWFormat)")
            return
        }
        
        inputEngine.connect(inputNode, to: inputEngine.mainMixerNode, format: inputHWFormat)
        
        // Connect the mixer to the output node to drive the engine's render thread and the tap.
        if inputDevice.isOutput {
            // Duplex device (e.g. BlackHole)
            _ = setDeviceID(inputDevice.deviceID, for: inputEngine.outputNode)
            inputEngine.connect(inputEngine.mainMixerNode, to: inputEngine.outputNode, format: inputHWFormat)
        } else {
            // Input-only device (e.g. USB Mic)
            let outputFormat = inputEngine.outputNode.outputFormat(forBus: 0)
            inputEngine.connect(inputEngine.mainMixerNode, to: inputEngine.outputNode, format: outputFormat)
        }
        inputEngine.mainMixerNode.outputVolume = 0.0
        
        installTap(on: inputNode, format: inputHWFormat, ringBuffer: ringBuffer)
        
        // --- Output Engine Setup ---
        let outputNode = outputEngine.outputNode
        let isOutputDeviceSet = setDeviceID(outputDevice.deviceID, for: outputNode)
        guard isOutputDeviceSet else {
            print("Failed to set output device")
            inputNode.removeTap(onBus: 0)
            return
        }
        
        let outputHWFormat = outputNode.outputFormat(forBus: 0)
        if inputHWFormat.sampleRate != outputHWFormat.sampleRate {
            print("WARNING: Input sample rate (\(inputHWFormat.sampleRate)Hz) does not match output sample rate (\(outputHWFormat.sampleRate)Hz). This may cause pitch shifting or audio dropouts. Please configure both to the same rate in Audio MIDI Setup.")
        }
        
        // Create a fresh source node for the output engine
        let newSourceNode = createSourceNode(ringBuffer: ringBuffer)
        self.sourceNode = newSourceNode
        outputEngine.attach(newSourceNode)
        
        // Build the plugin chain
        rebuildOutputGraph()
        
        do {
            inputEngine.prepare()
            try inputEngine.start()
            
            outputEngine.prepare()
            try outputEngine.start()
            
            isRouting = true
            print("Audio routing started: \(inputDevice.name) → \(outputDevice.name) @ \(outputHWFormat.sampleRate)Hz")
        } catch {
            print("Error starting audio engines: \(error)")
            stop()
        }
    }
    
    func stop() {
        let wasRouting = isRouting
        isRouting = false
        
        // Tear down input engine
        if inputEngine.isRunning {
            inputEngine.stop()
        }
        inputEngine.inputNode.removeTap(onBus: 0)
        
        // Tear down output engine — detach all nodes cleanly
        if outputEngine.isRunning {
            outputEngine.stop()
        }
        
        // Detach all plugin nodes
        for pluginWrapper in activePlugins {
            if pluginWrapper.audioUnit.engine != nil {
                outputEngine.detach(pluginWrapper.audioUnit)
            }
        }
        
        // Detach the source node (do NOT re-attach it here — start() will create a fresh one)
        if let sourceNode = sourceNode, sourceNode.engine != nil {
            outputEngine.detach(sourceNode)
        }
        
        // Full reset of both engines to clear all internal state
        inputEngine.reset()
        outputEngine.reset()
        
        ringBuffer.clear()
        
        if wasRouting {
            print("Audio routing stopped.")
        }
    }
    
    // MARK: - Plugin Management
    
    func addPlugin(_ plugin: AVAudioUnit) {
        let active = ActivePlugin(audioUnit: plugin)
        activePlugins.append(active)
        
        if isRouting {
            // Attach the new plugin and rebuild connections
            outputEngine.attach(plugin)
            rebuildOutputGraph()
        }
    }
    
    func removePlugin(by id: UUID) {
        guard let index = activePlugins.firstIndex(where: { $0.id == id }) else { return }
        let plugin = activePlugins.remove(at: index).audioUnit
        
        // Detach from engine FIRST, then rebuild the graph without it
        if plugin.engine != nil {
            outputEngine.detach(plugin)
        }
        
        if isRouting {
            rebuildOutputGraph()
        }
    }
    
    func toggleBypass(for id: UUID) {
        guard let index = activePlugins.firstIndex(where: { $0.id == id }) else { return }
        let plugin = activePlugins[index].audioUnit
        if let effect = plugin as? AVAudioUnitEffect {
            effect.bypass.toggle()
        } else {
            plugin.auAudioUnit.shouldBypassEffect.toggle()
        }
    }
    
    func isBypassed(for id: UUID) -> Bool {
        guard let index = activePlugins.firstIndex(where: { $0.id == id }) else { return false }
        let plugin = activePlugins[index].audioUnit
        if let effect = plugin as? AVAudioUnitEffect {
            return effect.bypass
        } else {
            return plugin.auAudioUnit.shouldBypassEffect
        }
    }
    
    // MARK: - Graph Building
    
    /// Rebuilds the output engine's node connections: sourceNode → [plugins...] → mixer → output.
    /// This only reconnects nodes — it does NOT attach/detach nodes (except for safety checks).
    private func rebuildOutputGraph() {
        guard let sourceNode = sourceNode else { return }
        
        let wasRunning = outputEngine.isRunning
        if wasRunning {
            outputEngine.stop()
        }
        
        // Disconnect all existing connections
        outputEngine.disconnectNodeOutput(sourceNode)
        for pluginWrapper in activePlugins {
            let plugin = pluginWrapper.audioUnit
            outputEngine.disconnectNodeOutput(plugin)
            outputEngine.disconnectNodeInput(plugin)
        }
        outputEngine.disconnectNodeInput(outputEngine.mainMixerNode)
        
        // Ensure all plugin nodes are attached (safe — checks engine property first)
        for pluginWrapper in activePlugins {
            if pluginWrapper.audioUnit.engine == nil {
                outputEngine.attach(pluginWrapper.audioUnit)
            }
        }
        
        // Use the output hardware's native format for mixer -> output connection.
        // outputFormat(forBus: 0) reflects the actual hardware capabilities,
        // whereas inputFormat would return whatever was last connected (possibly stale).
        let outputHWFormat = outputEngine.outputNode.outputFormat(forBus: 0)
        guard outputHWFormat.sampleRate > 0, outputHWFormat.channelCount > 0 else {
            print("Invalid output hardware format: \(outputHWFormat)")
            return
        }
        
        // Define a clean, standard processing format (mono or stereo) at the hardware sample rate.
        // This avoids passing complex hardware channel layouts or high channel counts (e.g. 8ch, 16ch)
        // to third-party AU plugins, which often crash or fail to initialize on non-standard layouts.
        let processingChannels = min(2, outputHWFormat.channelCount)
        let processingFormat = AVAudioFormat(standardFormatWithSampleRate: outputHWFormat.sampleRate, channels: processingChannels)
        
        // Build the signal chain: source → plugin1 → plugin2 → ... → mixer → output
        var lastNode: AVAudioNode = sourceNode
        for pluginWrapper in activePlugins {
            let plugin = pluginWrapper.audioUnit
            outputEngine.connect(lastNode, to: plugin, format: processingFormat)
            lastNode = plugin
        }
        outputEngine.connect(lastNode, to: outputEngine.mainMixerNode, format: processingFormat)
        outputEngine.connect(outputEngine.mainMixerNode, to: outputEngine.outputNode, format: outputHWFormat)
        
        if wasRunning {
            do {
                try outputEngine.start()
            } catch {
                print("Failed to restart output engine after rebuilding graph: \(error)")
            }
        }
    }
    
    // MARK: - CoreAudio Helpers
    
    private func setDeviceID(_ deviceID: AudioDeviceID, for node: AVAudioIONode) -> Bool {
        guard let audioUnit = node.audioUnit else {
            return false
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }
    
    nonisolated private func installTap(on inputNode: AVAudioInputNode, format: AVAudioFormat, ringBuffer: AudioRingBuffer) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { bufferRef, time in
            if let channelData = bufferRef.floatChannelData {
                let channelCount = Int(bufferRef.format.channelCount)
                ringBuffer.write(channels: channelData, numChannels: channelCount, count: Int(bufferRef.frameLength))
            }
        }
    }
    
    // MARK: - Device Change Listener
    
    /// Listens for hardware device additions/removals (e.g., plugging in headphones)
    /// and auto-refreshes the device list.
    private func setupDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let block: AudioObjectPropertyListenerBlock = { [weak self] (numberAddresses, addresses) in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
            }
        }
        
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
        
        if status == noErr {
            self.deviceListenerBlock = block
        } else {
            print("Failed to add device change listener: \(status)")
        }
    }
    
    private func removeDeviceChangeListener() {
        guard let block = deviceListenerBlock else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
        deviceListenerBlock = nil
    }
    
    // MARK: - Configuration Change Observers
    
    /// Observes AVAudioEngine configuration changes (sample rate / channel count changes)
    /// on both engines and triggers a graceful restart.
    private func setupConfigurationChangeObservers() {
        inputConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: inputEngine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRouting else { return }
                print("Input engine configuration changed — restarting routing.")
                self.start()
            }
        }
        
        outputConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: outputEngine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRouting else { return }
                print("Output engine configuration changed — restarting routing.")
                self.start()
            }
        }
    }
}
