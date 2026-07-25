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
  private var audioUnit: AudioUnit?
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
    if let device, audioUnit != nil {
      lock.unlock()
      return device
    }
    lock.unlock()

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

    var componentDescription = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_HALOutput,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0
    )
    guard let component = AudioComponentFindNext(nil, &componentDescription) else {
      throw PhoneBridgeError.audioBridgeFailed("Core Audio HAL output component is unavailable.")
    }
    var newAudioUnit: AudioUnit?
    try Self.check(
      AudioComponentInstanceNew(component, &newAudioUnit),
      operation: "create virtual microphone HAL output"
    )
    guard let newAudioUnit else {
      throw PhoneBridgeError.audioBridgeFailed("Core Audio returned no virtual microphone HAL output.")
    }
    do {
      var enabled: UInt32 = 1
      try Self.check(
        AudioUnitSetProperty(
          newAudioUnit,
          kAudioOutputUnitProperty_EnableIO,
          kAudioUnitScope_Output,
          0,
          &enabled,
          UInt32(MemoryLayout<UInt32>.size)
        ),
        operation: "enable virtual microphone output"
      )
      var disabled: UInt32 = 0
      try Self.check(
        AudioUnitSetProperty(
          newAudioUnit,
          kAudioOutputUnitProperty_EnableIO,
          kAudioUnitScope_Input,
          1,
          &disabled,
          UInt32(MemoryLayout<UInt32>.size)
        ),
        operation: "disable virtual microphone input"
      )
      var selectedDeviceID = AudioDeviceID(selected.objectID)
      try Self.check(
        AudioUnitSetProperty(
          newAudioUnit,
          kAudioOutputUnitProperty_CurrentDevice,
          kAudioUnitScope_Global,
          0,
          &selectedDeviceID,
          UInt32(MemoryLayout<AudioDeviceID>.size)
        ),
        operation: "select virtual microphone device"
      )
      var format = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2 * UInt32(MemoryLayout<Float>.size),
        mFramesPerPacket: 1,
        mBytesPerFrame: 2 * UInt32(MemoryLayout<Float>.size),
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
      )
      try Self.check(
        AudioUnitSetProperty(
          newAudioUnit,
          kAudioUnitProperty_StreamFormat,
          kAudioUnitScope_Input,
          0,
          &format,
          UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ),
        operation: "configure virtual microphone format"
      )
      var callback = AURenderCallbackStruct(
        inputProc: virtualMicrophoneRenderCallback,
        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
      )
      try Self.check(
        AudioUnitSetProperty(
          newAudioUnit,
          kAudioUnitProperty_SetRenderCallback,
          kAudioUnitScope_Input,
          0,
          &callback,
          UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ),
        operation: "configure virtual microphone callback"
      )
      try Self.check(
        AudioUnitInitialize(newAudioUnit),
        operation: "initialize virtual microphone output"
      )
      lock.lock()
      audioUnit = newAudioUnit
      device = selected
      lock.unlock()
      try Self.check(
        AudioOutputUnitStart(newAudioUnit),
        operation: "start virtual microphone device"
      )
      return selected
    } catch {
      lock.lock()
      if audioUnit == newAudioUnit {
        audioUnit = nil
        device = nil
      }
      lock.unlock()
      _ = AudioUnitUninitialize(newAudioUnit)
      _ = AudioComponentInstanceDispose(newAudioUnit)
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
    let currentAudioUnit = audioUnit
    audioUnit = nil
    device = nil
    pcmBuffer.removeAll(keepingCapacity: false)
    lock.unlock()
    if let currentAudioUnit {
      _ = AudioOutputUnitStop(currentAudioUnit)
      _ = AudioUnitUninitialize(currentAudioUnit)
      _ = AudioComponentInstanceDispose(currentAudioUnit)
    }
  }

  deinit {
    stop()
  }

  fileprivate func fill(outputData: UnsafeMutablePointer<AudioBufferList>) {
    let buffers = UnsafeMutableAudioBufferListPointer(outputData)
    guard let firstBuffer = buffers.first else { return }
    let firstChannelCount = max(1, Int(firstBuffer.mNumberChannels))
    let frameCount =
      buffers.count == 1
      ? Int(firstBuffer.mDataByteSize) / (MemoryLayout<Float>.size * firstChannelCount)
      : Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
    guard frameCount > 0 else { return }

    lock.lock()
    guard audioUnit != nil else {
      lock.unlock()
      return
    }
    let availableFrames = min(frameCount, pcmBuffer.count / (2 * MemoryLayout<Int16>.size))
    let source = Data(pcmBuffer.prefix(availableFrames * 2 * MemoryLayout<Int16>.size))
    pcmBuffer.removeFirst(source.count)
    lock.unlock()

    for buffer in buffers {
      if let data = buffer.mData {
        memset(data, 0, Int(buffer.mDataByteSize))
      }
    }
    guard availableFrames > 0 else { return }
    source.withUnsafeBytes { rawBuffer in
      let samples = rawBuffer.bindMemory(to: Int16.self)
      if buffers.count == 1, let data = buffers[0].mData {
        let channels = max(1, Int(buffers[0].mNumberChannels))
        let output = data.assumingMemoryBound(to: Float.self)
        for frame in 0..<availableFrames {
          for channel in 0..<channels {
            let sourceChannel = min(channel, 1)
            output[frame * channels + channel] =
              Float(samples[frame * 2 + sourceChannel]) / Float(Int16.max)
          }
        }
      } else {
        for (channel, buffer) in buffers.enumerated() {
          guard let data = buffer.mData else { continue }
          let output = data.assumingMemoryBound(to: Float.self)
          let sourceChannel = min(channel, 1)
          for frame in 0..<availableFrames {
            output[frame] = Float(samples[frame * 2 + sourceChannel]) / Float(Int16.max)
          }
        }
      }
    }
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

private let virtualMicrophoneRenderCallback: AURenderCallback = {
  refCon, _, _, _, _, outputData in
  guard let outputData else { return noErr }
  let output = Unmanaged<VirtualMicrophoneOutput>.fromOpaque(refCon).takeUnretainedValue()
  output.fill(outputData: outputData)
  return noErr
}
