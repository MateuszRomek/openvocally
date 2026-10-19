import CoreAudio

enum CoreAudioDevices {
  static func inputDevices() -> [InputDevice] {
    let ids: [AudioDeviceID] = arrayProperty(
      AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    return ids.compactMap { id in
      guard let uid = uid(of: id) else { return nil }
      let transport: UInt32 = scalarProperty(id, kAudioDevicePropertyTransportType) ?? 0
      let alive: UInt32 = scalarProperty(id, kAudioDevicePropertyDeviceIsAlive) ?? 0
      return InputDevice(
        uid: uid,
        id: id,
        isAlive: alive != 0,
        hasInput: streamCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
        isAggregateOrVirtual: [
          kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate,
          kAudioDeviceTransportTypeVirtual,
        ].contains(transport),
        transport: Self.transport(transport)
      )
    }
  }

  private static func transport(_ type: UInt32) -> Microphone.Transport {
    switch type {
    case kAudioDeviceTransportTypeBuiltIn: .builtIn
    case kAudioDeviceTransportTypeUSB: .usb
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
    default: .other
    }
  }

  static func defaultInputUID() -> String? {
    let id: AudioDeviceID? = scalarProperty(
      AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
    return id.flatMap(uid(of:))
  }

  static func endpoints(chosenUID: String?) -> [AudioEndpoint] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let defaults: [AudioEndpoint.Direction: AudioDeviceID?] = [
      .input: scalarProperty(system, kAudioHardwarePropertyDefaultInputDevice),
      .output: scalarProperty(system, kAudioHardwarePropertyDefaultOutputDevice),
    ]
    let scopes: [(AudioEndpoint.Direction, AudioObjectPropertyScope)] = [
      (.input, kAudioObjectPropertyScopeInput), (.output, kAudioObjectPropertyScopeOutput),
    ]
    let ids: [AudioDeviceID] = arrayProperty(system, kAudioHardwarePropertyDevices)
    return scopes.flatMap { direction, scope in
      ids.compactMap { id -> AudioEndpoint? in
        let alive: UInt32 = scalarProperty(id, kAudioDevicePropertyDeviceIsAlive) ?? 0
        guard alive != 0, streamCount(id, scope: scope) > 0, let uid = uid(of: id) else { return nil }
        let transport: UInt32 = scalarProperty(id, kAudioDevicePropertyTransportType) ?? 0
        return AudioEndpoint(
          direction: direction, transport: Self.transport(transport),
          isSystemDefault: defaults[direction] == id, isChosen: direction == .input && uid == chosenUID)
      }
    }
  }

  private static func address(
    _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  /// Usable input devices by name, for the picker in Settings.
  static func microphones() -> MicrophoneList {
    let devices = inputDevices().filter(\.isUsable).map { device in
      Microphone(uid: device.uid, name: name(of: device.id) ?? device.uid, transport: device.transport)
    }
    return MicrophoneList(devices: devices, systemDefaultUID: defaultInputUID())
  }

  private static func name(of id: AudioDeviceID) -> String? {
    stringProperty(id, kAudioObjectPropertyName)
  }

  private static func uid(of id: AudioDeviceID) -> String? {
    stringProperty(id, kAudioDevicePropertyDeviceUID)
  }

  private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String?
  {
    var address = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }

  private static func scalarProperty<T: BitwiseCopyable>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> T? {
    var address = address(selector)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer -> T? in
      guard let base = buffer.baseAddress,
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, base) == noErr
      else { return nil }
      return base.pointee
    }
  }

  private static func arrayProperty<T: BitwiseCopyable>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> [T] {
    var address = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    let values = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
      initialized = 0
      guard let base = buffer.baseAddress,
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, base) == noErr
      else { return }
      initialized = Int(size) / MemoryLayout<T>.stride
    }
    return values
  }

  /// The input side's nominal rate. A Bluetooth headset reports its headset-profile rate here
  /// before any capture starts.
  static func nominalInputRate(of id: AudioDeviceID) -> Double? {
    var address = address(kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeInput)
    var rate = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr, rate > 0 else {
      return nil
    }
    return rate
  }

  private static func streamCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var address = address(kAudioDevicePropertyStreams, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
    return Int(size) / MemoryLayout<AudioStreamID>.stride
  }
}
