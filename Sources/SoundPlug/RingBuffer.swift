import Foundation
import AVFoundation
import os

/// A lock-free Single-Producer Single-Consumer (SPSC) ring buffer designed for
/// real-time audio. Uses os_atomic operations on read/write indices to synchronize
/// between the producer (input tap) and consumer (source node render) threads
/// without any blocking primitives.
///
/// - Important: This buffer must only be used with exactly **one writer thread**
///   and **one reader thread**. Multiple concurrent writers or readers will cause
///   data races.
final class AudioRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    // Use UnsafeMutablePointer<Int> for atomic-like access with stable addresses.
    // Since this is SPSC (single producer, single consumer), we only need
    // store-release/load-acquire semantics which are naturally satisfied on
    // ARM64 (Apple Silicon) for aligned pointer-width stores/loads.
    // On x86, all loads/stores have acquire/release semantics by default.
    private let _writeIndex: UnsafeMutablePointer<Int>
    private let _readIndex: UnsafeMutablePointer<Int>
    private let capacity: Int
    private let numChannels: Int
    
    init(capacity: Int = 131072, numChannels: Int = 2) {
        self.capacity = capacity
        self.numChannels = numChannels
        
        // Heap-allocate indices for stable memory address (required for cross-thread access)
        self._writeIndex = .allocate(capacity: 1)
        self._writeIndex.initialize(to: 0)
        self._readIndex = .allocate(capacity: 1)
        self._readIndex.initialize(to: 0)
        
        // Pre-allocate contiguous channel buffers using raw pointers
        // to avoid any Swift Array overhead in the real-time path.
        self.storage = .allocate(capacity: numChannels)
        for c in 0..<numChannels {
            let channelBuffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            channelBuffer.initialize(repeating: 0.0, count: capacity)
            storage[c] = channelBuffer
        }
    }
    
    deinit {
        for c in 0..<numChannels {
            storage[c].deinitialize(count: capacity)
            storage[c].deallocate()
        }
        storage.deallocate()
        _writeIndex.deinitialize(count: 1)
        _writeIndex.deallocate()
        _readIndex.deinitialize(count: 1)
        _readIndex.deallocate()
    }
    
    /// Returns the number of frames available for reading.
    @inline(__always)
    private func availableForReading(writeIdx: Int, readIdx: Int) -> Int {
        let diff = writeIdx - readIdx
        return diff >= 0 ? diff : diff + capacity
    }
    
    /// Called from the input tap thread (producer). Writes interleaved channel data
    /// into the ring buffer.
    func write(channels: UnsafePointer<UnsafeMutablePointer<Float>>, numChannels incomingChannels: Int, count: Int) {
        guard incomingChannels > 0, count > 0 else { return }
        
        let writeIdx = _writeIndex.pointee
        let framesToCopy = min(count, capacity - 1) // Leave 1 slot empty to distinguish full vs empty
        
        for c in 0..<numChannels {
            let srcChannelIdx = c % incomingChannels
            let src = channels[srcChannelIdx]
            let dst = storage[c]
            
            let firstChunk = min(framesToCopy, capacity - writeIdx)
            let secondChunk = framesToCopy - firstChunk
            
            // Copy first contiguous segment
            dst.advanced(by: writeIdx).update(from: src, count: firstChunk)
            
            // Wrap around and copy second segment if needed
            if secondChunk > 0 {
                dst.update(from: src.advanced(by: firstChunk), count: secondChunk)
            }
        }
        
        let newWriteIdx = (writeIdx + framesToCopy) % capacity
        _writeIndex.pointee = newWriteIdx
    }
    
    /// Called from the AVAudioSourceNode render callback (consumer).
    /// Reads frames into the provided AudioBufferList. Pads with silence
    /// if not enough data is available (underrun).
    func read(into audioBufferList: UnsafeMutablePointer<AudioBufferList>, count: Int) {
        guard count > 0 else { return }
        
        let readIdx = _readIndex.pointee
        let writeIdx = _writeIndex.pointee
        
        let available = availableForReading(writeIdx: writeIdx, readIdx: readIdx)
        let toRead = min(count, available)
        
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        
        for c in 0..<min(numChannels, abl.count) {
            guard let dest = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let src = storage[c]
            
            if toRead > 0 {
                let firstChunk = min(toRead, capacity - readIdx)
                let secondChunk = toRead - firstChunk
                
                // Copy first contiguous segment
                dest.update(from: src.advanced(by: readIdx), count: firstChunk)
                
                // Wrap around
                if secondChunk > 0 {
                    dest.advanced(by: firstChunk).update(from: src, count: secondChunk)
                }
            }
            
            // Zero-fill any remaining frames (underrun silence padding)
            if toRead < count {
                dest.advanced(by: toRead).initialize(repeating: 0.0, count: count - toRead)
            }
        }
        
        if toRead > 0 {
            let newReadIdx = (readIdx + toRead) % capacity
            _readIndex.pointee = newReadIdx
        }
    }
    
    /// Resets the buffer to empty state. Must only be called when neither the
    /// producer nor consumer is actively reading/writing (i.e., engines are stopped).
    func clear() {
        _writeIndex.pointee = 0
        _readIndex.pointee = 0
        for c in 0..<numChannels {
            storage[c].initialize(repeating: 0.0, count: capacity)
        }
    }
}
