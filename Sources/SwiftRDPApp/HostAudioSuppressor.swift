import CoreAudio
import Foundation
import SwiftRDPCore

/// Core Audio invokes this on its real-time thread; it must never touch actor state.
private func hostAudioSuppressorIOProc(
    _: AudioObjectID,
    _: UnsafePointer<AudioTimeStamp>,
    _: UnsafePointer<AudioBufferList>,
    _: UnsafePointer<AudioTimeStamp>,
    _: UnsafeMutablePointer<AudioBufferList>,
    _: UnsafePointer<AudioTimeStamp>,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    noErr
}

/// Temporarily prevents tapped system audio from reaching local hardware.
/// The Core Audio tap owns the mute, so destroying it (including on process exit)
/// restores normal host playback without changing the user's output volume.
@MainActor
final class HostAudioSuppressor {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    var isSuppressed: Bool {
        tapID != kAudioObjectUnknown && aggregateDeviceID != kAudioObjectUnknown
    }

    @discardableResult
    func setSuppressed(_ suppressed: Bool) -> Bool {
        if suppressed {
            return start()
        } else {
            stop()
            return true
        }
    }

    private func start() -> Bool {
        guard !isSuppressed else { return true }
        if tapID != kAudioObjectUnknown || aggregateDeviceID != kAudioObjectUnknown || ioProcID != nil {
            stop()
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "SwiftRDP Controller-Only Audio"
        description.muteBehavior = .muted
        description.isPrivate = true

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTap)
        guard tapStatus == noErr, createdTap != kAudioObjectUnknown else {
            RDPLog.app.error("Audio: failed to create host playback tap status=\(tapStatus)")
            return false
        }

        var createdAggregate = AudioObjectID(kAudioObjectUnknown)
        var createdIOProc: AudioDeviceIOProcID?
        var ioStarted = false
        var keepResources = false
        defer {
            if !keepResources {
                Self.destroyResources(
                    tapID: createdTap,
                    aggregateDeviceID: createdAggregate,
                    ioProcID: createdIOProc,
                    ioStarted: ioStarted
                )
            }
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SwiftRDP Controller-Only Audio",
            kAudioAggregateDeviceUIDKey: "com.swiftrdp.controller-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]],
            kAudioAggregateDeviceTapAutoStartKey: false
        ]
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &createdAggregate
        )
        guard aggregateStatus == noErr, createdAggregate != kAudioObjectUnknown else {
            RDPLog.app.error(
                "Audio: failed to create host playback aggregate status=\(aggregateStatus)"
            )
            return false
        }

        let ioStatus = AudioDeviceCreateIOProcID(
            createdAggregate,
            hostAudioSuppressorIOProc,
            nil,
            &createdIOProc
        )
        guard ioStatus == noErr, createdIOProc != nil else {
            RDPLog.app.error("Audio: failed to create host playback IOProc status=\(ioStatus)")
            return false
        }

        let startStatus = AudioDeviceStart(createdAggregate, createdIOProc)
        guard startStatus == noErr else {
            RDPLog.app.error("Audio: failed to start host playback tap status=\(startStatus)")
            return false
        }
        ioStarted = true

        tapID = createdTap
        aggregateDeviceID = createdAggregate
        ioProcID = createdIOProc
        keepResources = true
        RDPLog.app.notice("Audio: host playback suppressed for controller-only mode")
        return true
    }

    private func stop() {
        guard tapID != kAudioObjectUnknown || aggregateDeviceID != kAudioObjectUnknown || ioProcID != nil else {
            return
        }
        let oldTap = tapID
        let oldAggregate = aggregateDeviceID
        let oldIOProc = ioProcID
        tapID = kAudioObjectUnknown
        aggregateDeviceID = kAudioObjectUnknown
        ioProcID = nil
        let status = Self.destroyResources(
            tapID: oldTap,
            aggregateDeviceID: oldAggregate,
            ioProcID: oldIOProc,
            ioStarted: true
        )
        if status == noErr {
            RDPLog.app.notice("Audio: host playback restored")
        } else {
            RDPLog.app.error("Audio: failed to restore host playback status=\(status)")
        }
    }

    @discardableResult
    nonisolated private static func destroyResources(
        tapID: AudioObjectID,
        aggregateDeviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID?,
        ioStarted: Bool
    ) -> OSStatus {
        var firstError: OSStatus = noErr
        if ioStarted, aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if status != noErr, firstError == noErr { firstError = status }
        }
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            if status != noErr, firstError == noErr { firstError = status }
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status != noErr, firstError == noErr { firstError = status }
        }
        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr, firstError == noErr { firstError = status }
        }
        return firstError
    }

    deinit {
        Self.destroyResources(
            tapID: tapID,
            aggregateDeviceID: aggregateDeviceID,
            ioProcID: ioProcID,
            ioStarted: aggregateDeviceID != kAudioObjectUnknown
        )
    }
}
