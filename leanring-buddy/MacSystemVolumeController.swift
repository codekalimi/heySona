//
//  MacSystemVolumeController.swift
//  leanring-buddy
//
//  Reads and changes the Mac's output volume and mute state through Core
//  Audio. Uses the default output device's "virtual main volume", which is
//  the same control as the volume keys and menu bar slider. Needs no
//  permission prompt.
//

import AudioToolbox
import CoreAudio
import Foundation

struct MacSystemVolumeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum MacSystemVolumeController {
    /// Current output volume from 0 to 100.
    static func currentVolumePercent() throws -> Int {
        let outputDeviceID = try defaultOutputDeviceID()
        var volumeAddress = virtualMainVolumeAddress()
        var volumeScalar: Float32 = 0
        var volumeScalarSize = UInt32(MemoryLayout<Float32>.size)

        let readStatus = AudioObjectGetPropertyData(outputDeviceID, &volumeAddress, 0, nil, &volumeScalarSize, &volumeScalar)
        guard readStatus == noErr else {
            throw MacSystemVolumeError(message: "This output device doesn't report its volume (status \(readStatus)).")
        }
        return Int((volumeScalar * 100).rounded())
    }

    static func setVolumePercent(_ volumePercent: Int) throws {
        let clampedVolumePercent = max(0, min(100, volumePercent))
        let outputDeviceID = try defaultOutputDeviceID()
        var volumeAddress = virtualMainVolumeAddress()
        var volumeScalar = Float32(clampedVolumePercent) / 100
        let volumeScalarSize = UInt32(MemoryLayout<Float32>.size)

        let writeStatus = AudioObjectSetPropertyData(outputDeviceID, &volumeAddress, 0, nil, volumeScalarSize, &volumeScalar)
        guard writeStatus == noErr else {
            throw MacSystemVolumeError(message: "This output device doesn't allow changing its volume (status \(writeStatus)).")
        }

        // Raising the volume while muted would otherwise have no audible effect.
        if clampedVolumePercent > 0, (try? isMuted()) == true {
            try setMuted(false)
        }
    }

    static func isMuted() throws -> Bool {
        let outputDeviceID = try defaultOutputDeviceID()
        var muteAddress = muteAddressForOutput()
        var muteValue: UInt32 = 0
        var muteValueSize = UInt32(MemoryLayout<UInt32>.size)

        let readStatus = AudioObjectGetPropertyData(outputDeviceID, &muteAddress, 0, nil, &muteValueSize, &muteValue)
        guard readStatus == noErr else {
            throw MacSystemVolumeError(message: "This output device doesn't report mute (status \(readStatus)).")
        }
        return muteValue != 0
    }

    static func setMuted(_ shouldMute: Bool) throws {
        let outputDeviceID = try defaultOutputDeviceID()
        var muteAddress = muteAddressForOutput()
        var muteValue: UInt32 = shouldMute ? 1 : 0
        let muteValueSize = UInt32(MemoryLayout<UInt32>.size)

        let writeStatus = AudioObjectSetPropertyData(outputDeviceID, &muteAddress, 0, nil, muteValueSize, &muteValue)
        guard writeStatus == noErr else {
            throw MacSystemVolumeError(message: "This output device can't be muted (status \(writeStatus)).")
        }
    }

    // MARK: - Core Audio Plumbing

    private static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var defaultOutputDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
        var outputDeviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let readStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputDeviceAddress,
            0,
            nil,
            &outputDeviceIDSize,
            &outputDeviceID
        )
        guard readStatus == noErr, outputDeviceID != kAudioObjectUnknown else {
            throw MacSystemVolumeError(message: "No audio output device found.")
        }
        return outputDeviceID
    }

    private static func virtualMainVolumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func muteAddressForOutput() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
