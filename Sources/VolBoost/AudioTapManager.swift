import AppKit
import CoreAudio

// MARK: - Sample processing

/// Soft limiter: linear below `knee`, asymptotically approaching 1.0 above it.
/// Continuous in value and slope at the knee, so boosted audio saturates
/// instead of hard-clipping into square waves.
@inline(__always)
private func softLimit(_ x: Float) -> Float {
    let knee: Float = 0.7
    let magnitude = abs(x)
    if magnitude <= knee { return x }
    let over = (magnitude - knee) / (1 - knee)
    let limited = knee + (1 - knee) * (over / (1 + over))
    return x < 0 ? -limited : limited
}

// MARK: - CoreAudio property helpers

private func propertyAddress(_ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

private func readValue<T>(_ objectID: AudioObjectID,
                          _ selector: AudioObjectPropertySelector,
                          _ fallback: T) -> T? {
    var address = propertyAddress(selector)
    var size = UInt32(MemoryLayout<T>.size)
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { buffer.deallocate() }
    buffer.initialize(to: fallback)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
    return status == noErr ? buffer.pointee : nil
}

private func readString(_ objectID: AudioObjectID,
                        _ selector: AudioObjectPropertySelector) -> String? {
    var address = propertyAddress(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    // CoreAudio hands back a +1 reference, so take it as retained.
    let buffer = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
    defer { buffer.deallocate() }
    buffer.initialize(to: nil)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
    guard status == noErr, let unmanaged = buffer.pointee else { return nil }
    return unmanaged.takeRetainedValue() as String
}

private func readObjectIDs(_ objectID: AudioObjectID,
                           _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var address = propertyAddress(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0
    else { return [] }
    var ids = [AudioObjectID](repeating: kAudioObjectUnknown,
                              count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
}

// MARK: - One tap + aggregate device pipeline for a single process

/// Captures one process's output through a muted process tap, applies gain,
/// and re-renders the result to the default output device.
private final class TapSession {
    /// Read on the realtime IO thread, written from the main thread. A single
    /// aligned 32-bit store is atomic on every platform we target, so no lock
    /// (and therefore no priority inversion) is needed in the render callback.
    private let gainStorage = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    var gain: Float {
        get { gainStorage.pointee }
        set { gainStorage.pointee = max(0, newValue) }
    }

    init(processObjectID: AudioObjectID, pid: pid_t, outputDeviceUID: String, gain: Float) throws {
        gainStorage.initialize(to: max(0, gain))

        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.name = "VolBoost-\(pid)"
        description.uuid = UUID()
        description.isPrivate = true
        // Silence the app's own path to the hardware only while we are actively
        // reading the tap, so audio is never lost if our IOProc stops.
        description.muteBehavior = .mutedWhenTapped

        try TapError.check(AudioHardwareCreateProcessTap(description, &tapID),
                           "AudioHardwareCreateProcessTap")

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolBoost \(pid)",
            kAudioAggregateDeviceUIDKey: "com.volboost.aggregate.\(pid).\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        do {
            try TapError.check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
                "AudioHardwareCreateAggregateDevice")

            let storage = gainStorage
            try TapError.check(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
                    _, inputData, _, outputData, _ in
                    TapSession.render(gain: storage.pointee, input: inputData, output: outputData)
                },
                "AudioDeviceCreateIOProcIDWithBlock")

            try TapError.check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
            isRunning = true
        } catch {
            invalidate()
            throw error
        }
    }

    /// Realtime render callback. No allocation, locking, or Obj-C messaging.
    private static func render(gain: Float,
                               input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)

        let paired = min(inputBuffers.count, outputBuffers.count)
        for index in 0..<paired {
            let source = inputBuffers[index]
            let destination = outputBuffers[index]
            guard let sourceData = source.mData, let destinationData = destination.mData else {
                continue
            }
            let copyBytes = min(Int(source.mDataByteSize), Int(destination.mDataByteSize))

            if gain == 1 {
                memcpy(destinationData, sourceData, copyBytes)
            } else if gain == 0 {
                memset(destinationData, 0, copyBytes)
            } else {
                let samples = copyBytes / MemoryLayout<Float>.size
                let src = sourceData.assumingMemoryBound(to: Float.self)
                let dst = destinationData.assumingMemoryBound(to: Float.self)
                if gain <= 1 {
                    // Attenuation can never overshoot, so skip the limiter.
                    for sample in 0..<samples { dst[sample] = src[sample] * gain }
                } else {
                    for sample in 0..<samples { dst[sample] = softLimit(src[sample] * gain) }
                }
            }

            // The tap is stereo; silence any output channels it did not fill.
            if copyBytes < Int(destination.mDataByteSize) {
                memset(destinationData + copyBytes, 0,
                       Int(destination.mDataByteSize) - copyBytes)
            }
        }
        for index in paired..<outputBuffers.count {
            if let data = outputBuffers[index].mData {
                memset(data, 0, Int(outputBuffers[index].mDataByteSize))
            }
        }
    }

    func invalidate() {
        if isRunning {
            AudioDeviceStop(aggregateID, ioProcID)
            isRunning = false
        }
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        invalidate()
        gainStorage.deallocate()
    }
}

// MARK: - Errors

struct TapError: LocalizedError {
    let operation: String
    let status: OSStatus

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status != noErr else { return }
        throw TapError(operation: operation, status: status)
    }

    /// TCC refuses tap creation with these until audio-recording access is granted.
    var looksLikePermissionDenial: Bool {
        status == kAudioHardwareIllegalOperationError
            || status == kAudioHardwareNotRunningError
            || status == kAudioHardwareUnspecifiedError
            || status == -1
    }

    var errorDescription: String? {
        "\(operation) failed (\(status))"
    }
}

// MARK: - Manager

final class AudioTapManager: ObservableObject {

    struct AudioApp: Identifiable, Equatable {
        let id: pid_t
        let objectID: AudioObjectID
        let name: String
        let icon: NSImage?
        var gainPercent: Double   // 100 == unity
        var isMuted: Bool
        var boostEnabled: Bool
        var isControlled: Bool    // a tap pipeline is live for this app

        static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
            lhs.id == rhs.id
                && lhs.name == rhs.name
                && lhs.gainPercent == rhs.gainPercent
                && lhs.isMuted == rhs.isMuted
                && lhs.boostEnabled == rhs.boostEnabled
                && lhs.isControlled == rhs.isControlled
        }
    }

    static let maxBoostPercent: Double = 400

    @Published private(set) var apps: [AudioApp] = []

    private struct Settings {
        var gainPercent: Double = 100
        var isMuted = false
        var boostEnabled = false

        var linearGain: Float { isMuted ? 0 : Float(gainPercent / 100) }
        var needsTap: Bool { isMuted || abs(gainPercent - 100) > 0.5 }
    }

    private var settings: [pid_t: Settings] = [:]
    private var sessions: [pid_t: TapSession] = [:]
    private var refreshTimer: Timer?
    private var hasShownPermissionAlert = false

    // MARK: Lifecycle

    func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { [weak self] _, _ in
            self?.rebuildSessions()
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        for session in sessions.values { session.invalidate() }
        sessions.removeAll()
    }

    // MARK: Discovery

    private func refresh() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        var discovered: [AudioApp] = []
        var livePIDs: Set<pid_t> = []

        for objectID in readObjectIDs(AudioObjectID(kAudioObjectSystemObject),
                                      kAudioHardwarePropertyProcessObjectList) {
            guard let pid: pid_t = readValue(objectID, kAudioProcessPropertyPID, pid_t(0)),
                  pid > 0, pid != ownPID
            else { continue }

            livePIDs.insert(pid)

            let isRunningOutput = (readValue(objectID, kAudioProcessPropertyIsRunningOutput,
                                             UInt32(0)) ?? 0) == 1
            // Keep an app listed while we are actively controlling it, even if it
            // pauses briefly, so its row and slider do not flicker away.
            guard isRunningOutput || sessions[pid] != nil else { continue }

            let runningApp = NSRunningApplication(processIdentifier: pid)
            let bundleID = readString(objectID, kAudioProcessPropertyBundleID)
            // A second VolBoost instance would otherwise be offered as a target,
            // and tapping our own re-rendered output is a feedback loop.
            if let bundleID, bundleID == ownBundleID { continue }
            let name = runningApp?.localizedName
                ?? bundleID?.split(separator: ".").last.map(String.init)
                ?? "PID \(pid)"

            let appSettings = settings[pid] ?? Settings()
            discovered.append(AudioApp(id: pid,
                                       objectID: objectID,
                                       name: name,
                                       icon: runningApp?.icon,
                                       gainPercent: appSettings.gainPercent,
                                       isMuted: appSettings.isMuted,
                                       boostEnabled: appSettings.boostEnabled,
                                       isControlled: sessions[pid] != nil))
        }

        // Tear down pipelines for processes that are gone.
        for pid in Array(sessions.keys) where !livePIDs.contains(pid) {
            sessions.removeValue(forKey: pid)?.invalidate()
            settings.removeValue(forKey: pid)
        }

        let sorted = discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if sorted != apps { apps = sorted }
    }

    // MARK: Control

    func setGainPercent(_ percent: Double, for app: AudioApp) {
        var appSettings = settings[app.id] ?? Settings()
        appSettings.gainPercent = min(max(percent, 0), Self.maxBoostPercent)
        apply(appSettings, to: app)
    }

    func toggleMute(for app: AudioApp) {
        var appSettings = settings[app.id] ?? Settings()
        appSettings.isMuted.toggle()
        apply(appSettings, to: app)
    }

    func setBoostEnabled(_ enabled: Bool, for app: AudioApp) {
        var appSettings = settings[app.id] ?? Settings()
        appSettings.boostEnabled = enabled
        if !enabled { appSettings.gainPercent = min(appSettings.gainPercent, 100) }
        apply(appSettings, to: app)
    }

    private func apply(_ appSettings: Settings, to app: AudioApp) {
        settings[app.id] = appSettings

        if appSettings.needsTap, sessions[app.id] == nil {
            startSession(for: app, gain: appSettings.linearGain)
        } else {
            // Once a pipeline exists, keep it. Dragging back through 100% is a
            // passthrough memcpy, and tearing the aggregate device down mid-drag
            // would glitch the audio.
            sessions[app.id]?.gain = appSettings.linearGain
        }
        refresh()
    }

    private func startSession(for app: AudioApp, gain: Float) {
        guard let outputUID = defaultOutputDeviceUID() else { return }
        do {
            sessions[app.id] = try TapSession(processObjectID: app.objectID,
                                              pid: app.id,
                                              outputDeviceUID: outputUID,
                                              gain: gain)
        } catch let error as TapError {
            settings[app.id] = Settings()
            if error.looksLikePermissionDenial {
                presentPermissionAlert()
            } else {
                presentFailureAlert(error, appName: app.name)
            }
        } catch {
            settings[app.id] = Settings()
        }
    }

    /// Rebuild every live pipeline against the new default output device.
    private func rebuildSessions() {
        let controlled = sessions.keys.compactMap { pid in apps.first { $0.id == pid } }
        for session in sessions.values { session.invalidate() }
        sessions.removeAll()
        for app in controlled {
            let appSettings = settings[app.id] ?? Settings()
            if appSettings.needsTap { startSession(for: app, gain: appSettings.linearGain) }
        }
        refresh()
    }

    private func defaultOutputDeviceUID() -> String? {
        guard let deviceID: AudioObjectID = readValue(AudioObjectID(kAudioObjectSystemObject),
                                                      kAudioHardwarePropertyDefaultOutputDevice,
                                                      AudioObjectID(kAudioObjectUnknown)),
              deviceID != kAudioObjectUnknown
        else { return nil }
        return readString(deviceID, kAudioDevicePropertyDeviceUID)
    }

    // MARK: Alerts

    private func presentPermissionAlert() {
        guard !hasShownPermissionAlert else { return }
        hasShownPermissionAlert = true

        let alert = NSAlert()
        alert.messageText = "VolBoost needs audio-recording access"
        alert.informativeText = "macOS requires audio-recording permission to tap an app's output, "
            + "which is how VolBoost changes that app's volume — allow it, then move the slider again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentFailureAlert(_ error: TapError, appName: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't control \(appName)"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
