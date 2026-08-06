import AVFoundation
import CoreAudio
import Foundation

/// Микрофон глазами захвата (AVCaptureSession). Отдельно от `AudioInputDevice` намеренно:
/// HAL перечисляет устройства, которых захват не видит, и такая строка в меню была бы
/// мёртвой — галочка стоит, а запись всё равно идёт с системного входа.
public struct CaptureInputDevice: Identifiable, Equatable, Sendable {
    public let uid: String
    public let name: String

    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Микрофон в системе: `id` нужен аудиоюниту, `uid` стабилен между перезапусками и хранится в настройках.
public struct AudioInputDevice: Identifiable, Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String

    public init(id: AudioDeviceID, uid: String, name: String) {
        self.id = id
        self.uid = uid
        self.name = name
    }
}

/// Перечисление устройств ввода через CoreAudio HAL.
public enum AudioDeviceList {

    /// Служебные агрегаты macOS: система заводит их сама, чтобы следовать за устройством
    /// по умолчанию. Выбирать их пользователю незачем — в списке им не место.
    private static let hiddenUIDPrefix = "CADefaultDeviceAggregate"

    /// Все устройства системы, у которых есть входные каналы.
    public static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs()
            .compactMap(inputDevice(for:))
            .filter { !$0.uid.hasPrefix(hiddenUIDPrefix) && !$0.name.hasPrefix(hiddenUIDPrefix) }
    }

    /// Микрофоны так, как их видит захват, — тот же источник, из которого `CaptureRecorder`
    /// резолвит устройство по UID. Список меню обязан строиться именно отсюда.
    public static func captureInputDevices() -> [CaptureInputDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { CaptureInputDevice(uid: $0.uniqueID, name: $0.localizedName) }
    }

    /// Устройство по UID; nil, если такого больше нет (например, отключили).
    public static func device(uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    /// Системный микрофон по умолчанию; nil, если микрофонов нет вовсе.
    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    // MARK: - CoreAudio

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func inputDevice(for id: AudioDeviceID) -> AudioInputDevice? {
        guard hasInputChannels(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioInputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
    }

    /// Устройство считается микрофоном, если в input-скоупе есть хотя бы один канал.
    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }

        // AudioBufferList — структура переменной длины, поэтому сырая память на `size` байт.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    /// CFString-свойство. CoreAudio отдаёт строку с +1, поэтому забираем её как retained.
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
