import SwiftUI
import AVFoundation
import AppKit
import CoreAudioKit

@MainActor
struct ContentView: View {
    private let engineManager = AudioEngineManager.shared
    @State private var showingPluginPicker = false
    @State private var searchQuery = ""
    @State private var availablePlugins: [AVAudioUnitComponent] = []
    
    // Plugin editor window management — keyed by plugin UUID to prevent duplicates
    @State private var pluginWindows: [UUID: NSWindow] = [:]
    
    // System output restore state
    @State private var originalOutputDeviceID: AudioDeviceID?
    @State private var showingOutputConfirmation = false
    
    // Animation states
    @State private var isButtonHovered = false
    @State private var isAddHovered = false
    @State private var glowAnim = false
    
    var body: some View {
        VStack(spacing: 24) {
            // Header Section
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SoundPlug")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.purple, Color.indigo, Color.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    Text("System-Wide Audio Insert Host")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Status Indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(engineManager.isRouting ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .shadow(color: engineManager.isRouting ? .green : .red, radius: glowAnim ? 6 : 2)
                        .scaleEffect(glowAnim ? 1.2 : 1.0)
                        .animation(
                            engineManager.isRouting ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default,
                            value: glowAnim
                        )
                    
                    Text(engineManager.isRouting ? "ACTIVE" : "STOPPED")
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundStyle(engineManager.isRouting ? .green : .red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(engineManager.isRouting ? Color.green.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 1)
                )
            }
            .onAppear {
                glowAnim = true
            }
            
            // Permissions Guard
            if !engineManager.hasPermission {
                permissionRequiredView
            } else {
                mainControlsView
            }
        }
        .padding(28)
        .frame(minWidth: 680, minHeight: 520)
        .preferredColorScheme(.dark)
        .onAppear {
            engineManager.checkPermission()
            engineManager.refreshDevices()
            availablePlugins = PluginManager.shared.scanAvailablePlugins()
            
            // Capture the current system output device for potential restore
            originalOutputDeviceID = getCurrentSystemOutputDeviceID()
        }
    }
    
    // MARK: - Views
    
    private var permissionRequiredView: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.badge.xmark")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            
            Text("Microphone & Audio Input Permission Required")
                .font(.headline)
            
            Text("SoundPlug requires input permissions to capture system audio streams from loopback devices or microphones for processing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Button(action: {
                engineManager.requestPermissions { granted in
                    if granted {
                        engineManager.refreshDevices()
                    }
                }
            }) {
                Text("Grant Permissions")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .scaleEffect(isButtonHovered ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isButtonHovered)
            .onHover { hovering in
                isButtonHovered = hovering
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
    
    private var mainControlsView: some View {
        @Bindable var manager = engineManager
        return VStack(spacing: 20) {
            // Master Start Button
            Button(action: {
                if engineManager.isRouting {
                    engineManager.stop()
                } else {
                    engineManager.start()
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: engineManager.isRouting ? "stop.fill" : "play.fill")
                    Text(engineManager.isRouting ? "Stop Routing" : "Start Routing")
                        .fontWeight(.semibold)
                }
                .font(.title3)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: engineManager.isRouting 
                            ? [Color.red.opacity(0.8), Color.orange.opacity(0.8)] 
                            : [Color.purple, Color.blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(16)
                .shadow(
                    color: engineManager.isRouting 
                        ? Color.red.opacity(0.4) 
                        : Color.blue.opacity(0.4),
                    radius: isButtonHovered ? 12 : 6,
                    x: 0,
                    y: 4
                )
            }
            .buttonStyle(.plain)
            .scaleEffect(isButtonHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.5), value: isButtonHovered)
            .onHover { hovering in
                isButtonHovered = hovering
            }
            
            // Input / Output Config
            HStack(spacing: 16) {
                // Input Device Picker
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "input.usb")
                            .foregroundStyle(.purple)
                        Text("Input Loopback Source")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Picker("", selection: $manager.selectedInputDevice) {
                        Text("Select Input Source...").tag(nil as AudioDevice?)
                        ForEach(manager.availableInputs, id: \.self) { device in
                            Text(device.name).tag(device as AudioDevice?)
                        }
                    }
                    .labelsHidden()
                }
                .padding(12)
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)
                
                // Output Device Picker
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(.blue)
                        Text("Output Hardware")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Picker("", selection: $manager.selectedOutputDevice) {
                        Text("Select Output Device...").tag(nil as AudioDevice?)
                        ForEach(manager.availableOutputs, id: \.self) { device in
                            Text(device.name).tag(device as AudioDevice?)
                        }
                    }
                    .labelsHidden()
                }
                .padding(12)
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)
            }
            
            // Plugins Insert List
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Effects Signal Chain")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Button(action: {
                        engineManager.refreshDevices()
                        availablePlugins = PluginManager.shared.scanAvailablePlugins()
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh audio components list")
                }
                
                ScrollView {
                    VStack(spacing: 8) {
                        if engineManager.activePlugins.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "waveform.path")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.secondary.opacity(0.6))
                                Text("No active plugins. Click '+' to insert an effect.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                        } else {
                            ForEach(engineManager.activePlugins) { wrapper in
                                pluginRow(for: wrapper)
                            }
                        }
                        
                        // Add Plugin Row Trigger
                        Button(action: { showingPluginPicker = true }) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Insert Audio Unit Effect")
                            }
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(
                                        isAddHovered ? Color.purple.opacity(0.6) : Color.white.opacity(0.1),
                                        style: StrokeStyle(lineWidth: 1.5, dash: [6])
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { isAddHovered = $0 }
                        .sheet(isPresented: $showingPluginPicker) {
                            pluginPickerSheet
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            
            // Setup & Quick Action Guide
            setupGuideView
        }
    }
    
    private func pluginRow(for wrapper: ActivePlugin) -> some View {
        let plugin = wrapper.audioUnit
        let isBypassed = engineManager.isBypassed(for: wrapper.id)
        
        return HStack(spacing: 16) {
            Image(systemName: "slider.horizontal.3")
                .font(.title2)
                .foregroundStyle(isBypassed ? Color.secondary : Color.purple)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(isBypassed ? Color.secondary : Color.primary)
                
                Text("\(plugin.manufacturerName) • \(plugin.audioComponentDescription.componentTypeString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Active/Bypass Button
            Button(action: {
                engineManager.toggleBypass(for: wrapper.id)
            }) {
                let statusText = isBypassed ? "Bypassed" : "Active"
                let textColor = isBypassed ? Color.secondary : Color.green
                let bgColor = isBypassed ? Color.white.opacity(0.08) : Color.green.opacity(0.15)
                
                Text(statusText)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(textColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(bgColor)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            
            // Open Editor UI
            Button(action: {
                openPluginEditor(for: wrapper)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "macwindow")
                    Text("Open UI")
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.15))
                .foregroundStyle(.blue)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            
            // Remove Plugin
            Button(action: {
                // Close the editor window if open
                closePluginWindow(for: wrapper.id)
                engineManager.removePlugin(by: wrapper.id)
            }) {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isBypassed ? Color.clear : Color.purple.opacity(0.15), lineWidth: 1)
        )
    }
    
    private var setupGuideView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("System-Wide Loopback Guide")
                    .font(.headline)
                
                Spacer()
                
                // Show restore button if we've changed the output
                if originalOutputDeviceID != nil && hasBlackHoleAsSystemOutput {
                    Button(action: restoreSystemOutput) {
                        Text("Restore Original Output")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.8))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                
                // Programmatic change button helper if BlackHole output exists
                if hasBlackHoleOutput {
                    Button(action: { showingOutputConfirmation = true }) {
                        Text("Route macOS Output to BlackHole")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.purple.opacity(0.8))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .alert("Change System Output?", isPresented: $showingOutputConfirmation) {
                        Button("Route to BlackHole", role: .destructive) {
                            setSystemOutputToBlackHole()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will change your macOS system audio output to BlackHole. You will not hear any audio directly from your speakers until you change it back or click \"Restore Original Output\".")
                    }
                }
            }
            
            Text("To process system-wide audio, route all macOS sound to a virtual driver:")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            HStack(alignment: .top, spacing: 12) {
                guideStep(num: "1", desc: "Select 'BlackHole' as your macOS system output device in System Settings.")
                guideStep(num: "2", desc: "Set 'BlackHole' as the Input Loopback Source in SoundPlug.")
                guideStep(num: "3", desc: "Set your physical output (e.g. Speakers) in SoundPlug and click Start.")
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.03))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
    
    private func guideStep(num: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(num)
                .font(.system(.caption, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(.purple)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.purple.opacity(0.15)))
            Text(desc)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    
    private var pluginPickerSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Choose Audio Effect")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { showingPluginPicker = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search installed plugins...", text: $searchQuery)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color.white.opacity(0.08))
            .cornerRadius(10)
            
            // List of plugins
            List {
                let filtered = availablePlugins.filter { component in
                    searchQuery.isEmpty || 
                    component.name.localizedCaseInsensitiveContains(searchQuery) ||
                    component.manufacturerName.localizedCaseInsensitiveContains(searchQuery)
                }
                
                if filtered.isEmpty {
                    Text("No plugins found.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(filtered, id: \.name) { component in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(component.name)
                                    .fontWeight(.semibold)
                                Text("\(component.manufacturerName) • \(component.audioComponentDescription.componentTypeString)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add") {
                                addSelectedPlugin(component)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(24)
        .frame(width: 450, height: 500)
    }
    
    // MARK: - Actions
    
    private func addSelectedPlugin(_ component: AVAudioUnitComponent) {
        showingPluginPicker = false
        PluginManager.shared.instantiatePlugin(component: component) { audioUnit, error in
            guard let audioUnit = audioUnit, error == nil else {
                print("Failed to instantiate audio unit: \(String(describing: error))")
                return
            }
            engineManager.addPlugin(audioUnit)
        }
    }
    
    /// Opens the plugin's native UI using the official AUAudioUnit.requestViewController API.
    /// Stores the window reference to prevent duplicates and manage lifecycle.
    private func openPluginEditor(for wrapper: ActivePlugin) {
        let pluginID = wrapper.id
        let audioUnit = wrapper.audioUnit
        let title = audioUnit.name
        
        // If a window is already open for this plugin, bring it to front
        if let existingWindow = pluginWindows[pluginID], existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        
        // Use the official public API — AUAudioUnit.requestViewController(completionHandler:)
        audioUnit.auAudioUnit.requestViewController { [self] viewController in
            DispatchQueue.main.async {
                guard let viewController = viewController else {
                    self.showNoPluginInterfaceAlert(title: title)
                    return
                }
                
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 650, height: 450),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "SoundPlug — \(title)"
                window.contentViewController = viewController
                window.center()
                window.isReleasedWhenClosed = false
                
                // Set up a delegate to clean up when the window closes
                let delegate = PluginWindowDelegate(pluginID: pluginID) { closedID in
                    Task { @MainActor in
                        self.pluginWindows.removeValue(forKey: closedID)
                    }
                }
                window.delegate = delegate
                
                // Store reference to prevent GC and allow lifecycle management
                self.pluginWindows[pluginID] = window
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
    
    private func closePluginWindow(for pluginID: UUID) {
        if let window = pluginWindows[pluginID] {
            window.close()
            pluginWindows.removeValue(forKey: pluginID)
        }
    }
    
    private func showNoPluginInterfaceAlert(title: String) {
        let alert = NSAlert()
        alert.messageText = "Plugin Interface"
        alert.informativeText = "The plugin '\(title)' does not provide a custom graphical interface."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    // MARK: - System Output Management
    
    private var hasBlackHoleOutput: Bool {
        engineManager.availableOutputs.contains(where: { $0.name.lowercased().contains("blackhole") })
    }
    
    private var hasBlackHoleAsSystemOutput: Bool {
        guard let currentID = getCurrentSystemOutputDeviceID() else { return false }
        return engineManager.availableOutputs.contains(where: {
            $0.deviceID == currentID && $0.name.lowercased().contains("blackhole")
        })
    }
    
    private func getCurrentSystemOutputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }
    
    private func setSystemOutputToBlackHole() {
        // Save original before changing
        if originalOutputDeviceID == nil {
            originalOutputDeviceID = getCurrentSystemOutputDeviceID()
        }
        
        if let blackhole = engineManager.availableOutputs.first(where: { $0.name.lowercased().contains("blackhole") }) {
            var id = blackhole.deviceID
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &id
            )
            if status == noErr {
                engineManager.refreshDevices()
            }
        }
    }
    
    private func restoreSystemOutput() {
        guard let originalID = originalOutputDeviceID else { return }
        var id = originalID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        if status == noErr {
            originalOutputDeviceID = nil
            engineManager.refreshDevices()
        }
    }
}

// MARK: - Plugin Window Delegate

/// Handles cleanup when a plugin editor window is closed. Stored as the window's delegate
/// and calls back to ContentView to remove the window reference.
final class PluginWindowDelegate: NSObject, NSWindowDelegate, @unchecked Sendable {
    let pluginID: UUID
    let onClose: @Sendable (UUID) -> Void
    
    init(pluginID: UUID, onClose: @escaping @Sendable (UUID) -> Void) {
        self.pluginID = pluginID
        self.onClose = onClose
    }
    
    func windowWillClose(_ notification: Notification) {
        onClose(pluginID)
    }
}

// MARK: - Extensions

extension AudioComponentDescription {
    var componentTypeString: String {
        switch componentType {
        case kAudioUnitType_Effect:
            return "Effect"
        case kAudioUnitType_MusicEffect:
            return "Music Effect"
        default:
            return "Other"
        }
    }
}
