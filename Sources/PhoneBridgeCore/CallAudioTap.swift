import AudioToolbox
import CoreAudio
import Foundation

public struct CapturedAudioFrame: @unchecked Sendable {
  public let sampleRate: Double
  public let channelCount: UInt32
  public let frameCount: UInt32
  public let formatFlags: AudioFormatFlags
  public let buffers: [Data]
}

public struct CallAudioTapDescription: Codable, Sendable, Equatable {
  public let bundleIdentifier: String
  public let processObjectIDs: [UInt32]
  public let sampleRate: Double
  public let channelCount: UInt32
}

public final class CallAudioTap: @unchecked Sendable {
  public typealias FrameHandler = @Sendable (CapturedAudioFrame) -> Void

  private let queue = DispatchQueue(label: "phonebridge.audio.tap", qos: .userInteractive)
  private let lock = NSLock()
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
  private var ioProcID: AudioDeviceIOProcID?
  private var streamDescription = AudioStreamBasicDescription()
  private var running = false

  public init() {}

  public func start(
    bundleIdentifier: String,
    frameHandler: @escaping FrameHandler
  ) throws -> CallAudioTapDescription {
    lock.lock()
    defer { lock.unlock() }
    guard !running else {
      throw PhoneBridgeError.audioBridgeFailed("A process tap is already running.")
    }
    guard #available(macOS 14.2, *) else {
      throw PhoneBridgeError.unsupportedPlatform("Core Audio process taps require macOS 14.2.")
    }

    let processObjectIDs = try Self.processObjectIDs(bundleIdentifier: bundleIdentifier)
    guard !processObjectIDs.isEmpty else {
      throw PhoneBridgeError.audioBridgeFailed(
        "No Core Audio process is active for \(bundleIdentifier). Start the call host first."
      )
    }

    do {
      let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
      tapDescription.uuid = UUID()
      tapDescription.name = "PhoneBridge \(bundleIdentifier)"
      tapDescription.isPrivate = true
      tapDescription.muteBehavior = .unmuted

      try Self.check(
        AudioHardwareCreateProcessTap(tapDescription, &tapID),
        operation: "create process tap"
      )
      streamDescription = try Self.read(
        objectID: tapID,
        selector: kAudioTapPropertyFormat,
        defaultValue: AudioStreamBasicDescription()
      )

      let outputDevice: AudioDeviceID = try Self.read(
        objectID: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        defaultValue: AudioDeviceID(kAudioObjectUnknown)
      )
      let outputUID = try Self.readString(
        objectID: outputDevice,
        selector: kAudioDevicePropertyDeviceUID
      )
      let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: "PhoneBridge Call Audio",
        kAudioAggregateDeviceUIDKey: "com.isaacthoman.phonebridge.tap.\(UUID().uuidString)",
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [
          [kAudioSubDeviceUIDKey: outputUID]
        ],
        kAudioAggregateDeviceTapListKey: [
          [
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
          ]
        ],
      ]
      try Self.check(
        AudioHardwareCreateAggregateDevice(
          aggregateDescription as CFDictionary,
          &aggregateDeviceID
        ),
        operation: "create aggregate tap device"
      )

      let format = streamDescription
      let ioBlock: AudioDeviceIOBlock = {
        _, inputData, _, _, _ in
        let mutableInputData = UnsafeMutablePointer(mutating: inputData)
        let buffers = UnsafeMutableAudioBufferListPointer(mutableInputData).map { buffer in
          guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return Data() }
          return Data(bytes: data, count: Int(buffer.mDataByteSize))
        }
        frameHandler(
          CapturedAudioFrame(
            sampleRate: format.mSampleRate,
            channelCount: format.mChannelsPerFrame,
            frameCount: Self.frameCount(inputData: inputData, format: format),
            formatFlags: format.mFormatFlags,
            buffers: buffers
          ))
      }
      try Self.check(
        AudioDeviceCreateIOProcIDWithBlock(
          &ioProcID,
          aggregateDeviceID,
          queue,
          ioBlock
        ),
        operation: "create tap I/O callback"
      )
      try Self.check(
        AudioDeviceStart(aggregateDeviceID, ioProcID),
        operation: "start aggregate tap device"
      )
      running = true
      return CallAudioTapDescription(
        bundleIdentifier: bundleIdentifier,
        processObjectIDs: processObjectIDs,
        sampleRate: streamDescription.mSampleRate,
        channelCount: streamDescription.mChannelsPerFrame
      )
    } catch {
      cleanup()
      throw error
    }
  }

  public func stop() {
    lock.lock()
    defer { lock.unlock() }
    cleanup()
  }

  deinit {
    stop()
  }

  private func cleanup() {
    if aggregateDeviceID != kAudioObjectUnknown {
      _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
      if let ioProcID {
        _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
      }
      _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    }
    if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
      _ = AudioHardwareDestroyProcessTap(tapID)
    }
    ioProcID = nil
    aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    tapID = AudioObjectID(kAudioObjectUnknown)
    running = false
  }

  private static func processObjectIDs(bundleIdentifier: String) throws -> [AudioObjectID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var byteCount: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(system, &address, 0, nil, &byteCount),
      operation: "read audio process list size"
    )
    var objectIDs = [AudioObjectID](
      repeating: kAudioObjectUnknown,
      count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
    )
    try check(
      AudioObjectGetPropertyData(system, &address, 0, nil, &byteCount, &objectIDs),
      operation: "read audio process list"
    )
    return objectIDs.filter { objectID in
      let value: CFString? = try? readString(
        objectID: objectID,
        selector: kAudioProcessPropertyBundleID
      )
      return value as String? == bundleIdentifier
    }
  }

  private static func read<T: BitwiseCopyable>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    defaultValue: T
  ) throws -> T {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value = defaultValue
    var byteCount = UInt32(MemoryLayout<T>.size)
    try check(
      AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value),
      operation: "read Core Audio property \(selector)"
    )
    return value
  }

  private static func readString(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) throws -> CFString {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(
      AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value),
      operation: "read Core Audio string property \(selector)"
    )
    guard let value else {
      throw PhoneBridgeError.audioBridgeFailed(
        "Core Audio string property \(selector) returned no value.")
    }
    return value.takeUnretainedValue()
  }

  private static func frameCount(
    inputData: UnsafePointer<AudioBufferList>,
    format: AudioStreamBasicDescription
  ) -> UInt32 {
    guard format.mBytesPerFrame > 0 else { return 0 }
    return inputData.pointee.mBuffers.mDataByteSize / format.mBytesPerFrame
  }

  private static func check(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
      throw PhoneBridgeError.audioBridgeFailed("\(operation) returned OSStatus \(status).")
    }
  }
}
