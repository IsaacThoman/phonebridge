import AudioToolbox
import CoreAudio
import Foundation

public struct AudioOutputDevice: Codable, Sendable, Equatable {
  public let objectID: UInt32
  public let name: String
  public let uid: String
}

public final class VirtualMicrophoneOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var audioQueue: AudioQueueRef?
  private var pcmBuffer = Data()
  private(set) public var device: AudioOutputDevice?

  public init() {}

  public static func devices() throws -> [AudioOutputDevice] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let system = AudioObjectID(kAudioObjectSystemObject)
    var byteCount: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(system, &address, 0, nil, &byteCount),
      operation: "read audio device list size"
    )
    var deviceIDs = [AudioDeviceID](
      repeating: kAudioObjectUnknown,
      count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size
    )
    try check(
      AudioObjectGetPropertyData(system, &address, 0, nil, &byteCount, &deviceIDs),
      operation: "read audio device list"
    )
    return deviceIDs.compactMap { deviceID in
      guard
        let name = try? readString(
          objectID: deviceID,
          selector: kAudioObjectPropertyName
        ),
        let uid = try? readString(
          objectID: deviceID,
          selector: kAudioDevicePropertyDeviceUID
        )
      else { return nil }
      return AudioOutputDevice(objectID: deviceID, name: name, uid: uid)
    }
  }

  @discardableResult
  public func start(
    preferredDeviceNames: [String] = ["BlackHole 2ch", "Loopback Audio 2", "Loopback Audio"]
  ) throws -> AudioOutputDevice {
    lock.lock()
    defer { lock.unlock() }
    if let device, audioQueue != nil { return device }

    let availableDevices = try Self.devices()
    guard
      let selected = preferredDeviceNames.lazy.compactMap({ preferredName in
        availableDevices.first(where: {
          $0.name.localizedCaseInsensitiveContains(preferredName)
        })
      }).first
    else {
      throw PhoneBridgeError.audioBridgeFailed(
        "No supported virtual microphone is installed (BlackHole 2ch or Loopback Audio)."
      )
    }

    var format = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 16,
      mReserved: 0
    )
    var queue: AudioQueueRef?
    let context = Unmanaged.passUnretained(self).toOpaque()
    try Self.check(
      AudioQueueNewOutput(
        &format,
        virtualMicrophoneOutputCallback,
        context,
        nil,
        nil,
        0,
        &queue
      ),
      operation: "create virtual microphone output queue"
    )
    guard let queue else {
      throw PhoneBridgeError.audioBridgeFailed("Core Audio returned no output queue.")
    }
    var unmanagedUID = Unmanaged.passUnretained(selected.uid as CFString)
    do {
      try Self.check(
        AudioQueueSetProperty(
          queue,
          kAudioQueueProperty_CurrentDevice,
          &unmanagedUID,
          UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        ),
        operation: "select virtual microphone output"
      )
      for _ in 0..<3 {
        var buffer: AudioQueueBufferRef?
        try Self.check(
          AudioQueueAllocateBuffer(queue, 1_920, &buffer),
          operation: "allocate virtual microphone buffer"
        )
        guard let buffer else { continue }
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        memset(buffer.pointee.mAudioData, 0, capacity)
        buffer.pointee.mAudioDataByteSize = UInt32(capacity)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
      }
      try Self.check(
        AudioQueueStart(queue, nil),
        operation: "start virtual microphone output"
      )
      audioQueue = queue
      device = selected
      return selected
    } catch {
      AudioQueueDispose(queue, true)
      throw error
    }
  }

  public func enqueuePCM16(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    pcmBuffer.append(data)
    let maximumBytes = 48_000 * 2 * MemoryLayout<Int16>.size * 2
    if pcmBuffer.count > maximumBytes {
      pcmBuffer.removeFirst(pcmBuffer.count - maximumBytes)
    }
    lock.unlock()
  }

  public func stop() {
    lock.lock()
    let queue = audioQueue
    audioQueue = nil
    device = nil
    pcmBuffer.removeAll(keepingCapacity: false)
    lock.unlock()
    if let queue {
      AudioQueueStop(queue, true)
      AudioQueueDispose(queue, true)
    }
  }

  deinit {
    stop()
  }

  fileprivate func fillAndEnqueue(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
    lock.lock()
    guard audioQueue == queue else {
      lock.unlock()
      return
    }
    let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
    let byteCount = min(capacity, pcmBuffer.count)
    memset(buffer.pointee.mAudioData, 0, capacity)
    if byteCount > 0 {
      pcmBuffer.copyBytes(
        to: buffer.pointee.mAudioData.assumingMemoryBound(to: UInt8.self),
        count: byteCount
      )
      pcmBuffer.removeFirst(byteCount)
    }
    buffer.pointee.mAudioDataByteSize = UInt32(capacity)
    lock.unlock()
    AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
  }

  private static func readString(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) throws -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(
      AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value),
      operation: "read audio device property \(selector)"
    )
    guard let value else {
      throw PhoneBridgeError.audioBridgeFailed("Audio device property was empty.")
    }
    return value.takeUnretainedValue() as String
  }

  private static func check(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
      throw PhoneBridgeError.audioBridgeFailed("\(operation) returned OSStatus \(status).")
    }
  }
}

private let virtualMicrophoneOutputCallback: AudioQueueOutputCallback = {
  userData, queue, buffer in
  guard let userData else { return }
  let output = Unmanaged<VirtualMicrophoneOutput>.fromOpaque(userData).takeUnretainedValue()
  output.fillAndEnqueue(queue: queue, buffer: buffer)
}
