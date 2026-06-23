# SoundPlug 🔌

SoundPlug is a powerful, low-latency, system-wide Audio Unit (AU) plugin host for macOS. It allows you to route all system audio (Spotify, web browsers, YouTube, DAWs, etc.) through your favorite commercial AU plugins (like EQs, compressors, limiters, and reverbs) in real-time before it reaches your speakers or headphones.

SoundPlug features a premium, responsive SwiftUI interface designed with rich dark-mode aesthetics, subtle glassmorphism, and micro-animations.

---

## Architecture Overview

SoundPlug uses a unique **dual-engine architecture** to bypass limitations in macOS audio routing:

```
[System Audio (Safari, Spotify, etc.)]
                │
                ▼ (Set System Output to Loopback)
       [BlackHole 2ch] (Virtual Device)
                │
                ▼ (Tapped in Real-time)
         ┌──────────────┐
         │ Input Engine │
         └──────┬───────┘
                │
                ▼ (Lock-Free Write)
      ┌────────────────────┐
      │  AudioRingBuffer   │  (SPSC Lock-free Ring Buffer)
      └─────────┬──────────┘
                │
                ▼ (Lock-Free Read)
        ┌───────────────┐
        │ Output Engine │
        └───────┬───────┘
                │
                ▼ (Standard Mono/Stereo Format)
    ┌───────────────────────┐
    │   AU Plugin Chain     │  (FabFilter, Reverbs, etc.)
    └───────────┬───────────┘
                │
                ▼ (Hardware Format)
      ┌──────────────────┐
      │  Physical Output │  (Headphones, Speakers, DAC)
      └──────────────────┘
```

1. **Input Engine**: Configured to use the loopback source (e.g., BlackHole 2ch) as its input. An input tap reads audio packets from the hardware driver in real-time.
2. **AudioRingBuffer**: A custom, lock-free, Single-Producer Single-Consumer (SPSC) ring buffer implemented in Swift. It uses pre-allocated raw float pointers and atomic-like memory offsets to safely transfer audio data between the input tap thread (producer) and the output render thread (consumer) without thread contention or blocking.
3. **Output Engine**: Runs a custom source node (`AVAudioSourceNode`) which pulls samples from the ring buffer. It passes this audio stream through a chain of dynamically inserted AU plugins, mixes it using the engine's main mixer, and renders it out to the physical speakers/headphones.
4. **Format & Layout Safety Isolation**: Third-party plugins (especially legacy AUv2 plugins) often crash or fail to initialize when configured with raw hardware stream formats that contain high channel counts (e.g. 8-channel HDMI, 16-channel virtual drivers) or complex channel layouts. SoundPlug solves this by processing the plugin chain in a standard mono/stereo configuration (`AVAudioFormat`) and letting the output engine's mixer automatically and safely handle the upmixing/downmixing to the physical hardware.

---

## Prerequisites

* **macOS**: Version 14.0 (Sonoma) or newer.
* **Xcode / Swift**: Swift 6.0 / 6.3 compiler.
* **Virtual Audio Driver**: A loopback driver is required to capture system audio. We recommend:
  * **BlackHole 2ch** (Free & Open Source) — [Download Link](https://github.com/ExistentialAudio/BlackHole) or install via Homebrew:
    ```bash
    brew install blackhole-2ch
    ```

---

## Installation & Building

Since SoundPlug is a standard Swift Package Manager executable, you can build and run it directly from the terminal or open it in Xcode.

### Via Command Line

1. Clone or navigate to the SoundPlug directory:
   ```bash
   cd /Users/zaid/Desktop/Projects/SoundPlug
   ```
2. Build the project:
   ```bash
   swift build -c release
   ```
3. Run the compiled executable:
   ```bash
   .build/release/SoundPlug
   ```

### Via Xcode

1. Open Xcode.
2. Choose **Open a Project or File** and select the root directory `/Users/zaid/Desktop/Projects/SoundPlug` (Xcode will automatically load it as a Swift Package).
3. Select the `SoundPlug` executable run scheme.
4. Click **Run** (Cmd + R).

---

## Full Setup & Audio Routing Guide

Follow these steps to route your Mac's system-wide audio through SoundPlug:

### Step 1: Install Virtual Driver
Ensure you have **BlackHole 2ch** installed on your Mac.

### Step 2: Open SoundPlug & Grant Permissions
Launch the SoundPlug app. Since it captures audio from an input device, macOS will request **Microphone / Audio Input Permission**. Click **Grant Permissions** and approve the system dialog.

### Step 3: Configure Routing Parameters
In the SoundPlug control panel:
1. **Input Loopback Source**: Select **BlackHole 2ch**.
2. **Output Device**: Select your physical playback device (e.g., *MacBook Pro Speakers*, *External Headphones*, or your USB DAC).

### Step 4: Route System Audio to BlackHole
You need to tell macOS to output its audio to the virtual device instead of your speakers:
* **Option A (Automatic)**: Click the **Route system audio to BlackHole** button inside SoundPlug. Confirm the prompt.
* **Option B (Manual)**: Go to **System Settings** -> **Sound** -> **Output** and select **BlackHole 2ch**.

### Step 5: Start Routing
Click the large **Start Routing** button in SoundPlug. The status indicator will turn **ACTIVE** (Green).

### Step 6: Load and Edit Plugins
1. Click the **+ Add Plugin** button.
2. Search and select any scanned AU plugin from your system (e.g., *FabFilter Pro-Q 4*).
3. The plugin will appear in the active chain list.
4. Click on the plugin's name to open its native GUI editor window.
5. You can bypass plugins using the power icon, drag them to re-order the processing chain, or delete them using the trash icon.

### Step 7: Tearing Down & Restoring Output
To stop routing:
1. Click **Stop Routing**.
2. To restore system audio back to your speakers, click the **Restore Original Output** button (or manually change macOS output back to your speakers in System Settings).

---

## Concurrency & Platform Compatibility

* **Strict Concurrency**: Fully compliant with Swift 6 strict concurrency checks. Actor isolation is cleanly maintained via `@MainActor` for window management and UI elements.
* **Platform compatibility**: Explicitly optimized for macOS 14+, avoiding macOS 15-only APIs (like `Synchronization.Atomic`) and preferring stable heap-allocated pointers with release/acquire semantics.
* **Thread Safety**: SPSC ring buffer operations run off the main thread in a lock-free realtime context, ensuring zero audio glitches/dropouts (underruns) even under heavy CPU loads.

---

## License

Created for system-wide audio plug-in hosting on macOS. All rights reserved.
