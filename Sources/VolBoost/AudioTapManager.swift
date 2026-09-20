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

/// Captures one process's output through a process tap and, when live,
/// re-renders it with gain to the default output device.
///
/// A session starts as a **probe** whenever we do not yet know that macOS will
/// actually hand us this process's audio. `AudioHardwareCreateProcessTap`
/// returns noErr for a tap it will only ever feed silence — audio-recording
/// access missing, or audio it protects — so the status code cannot tell us the
/// pipeline is alive. A probe leaves the app's own path to the hardware unmuted
/// and writes silence to the device, which is inaudible either way, while it
/// watches for a single non-zero sample. Only once one arrives does the manager
/// replace it with a live session that mutes the app and renders in its place.
/// Nothing the user hears can therefore be lost to a tap that never worked.
private final class TapSession {
    let isProbe: Bool

    /// Read on the realtime IO thread, written from the main thread. A single
    /// aligned 32-bit store is atomic on every platform we target, so no lock
    /// (and therefore no priority inversion) is needed in the render callback.
    private let gainStorage = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    /// Written on the IO thread, read from the main thread — same single-aligned-
    /// 32-bit-store argument as the gain.
    private struct Stats {
        var sawAudio: UInt32 = 0
        var silentSamples: UInt32 = 0
    }
    private let statsStorage = UnsafeMutablePointer<Stats>.allocate(capacity: 1)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    /// Ignored by a probe's render, which always writes silence, but kept so the
    /// value survives the switch to a live session.
    var gain: Float {
        get { gainStorage.pointee }
        set { gainStorage.pointee = max(0, newValue) }
    }

    /// True once the tap has handed us any non-zero sample.
    var hasDeliveredAudio: Bool { statsStorage.pointee.sawAudio != 0 }

    /// Samples of unbroken silence since the tap started, counted only until the
    /// first real sample arrives. Roughly 96k per second of stereo 48 kHz.
    var silentSampleCount: UInt32 { statsStorage.pointee.silentSamples }

    init(processObjectID: AudioObjectID, pid: pid_t, outputDeviceUID: String,
         gain: Float, probe: Bool) throws {
        isProbe = probe
        gainStorage.initialize(to: max(0, gain))
        statsStorage.initialize(to: Stats())

        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.name = "VolBoost-\(pid)"
        description.uuid = UUID()
        description.isPrivate = true
        // Live: silence the app's own path to the hardware only while we are
        // actively reading the tap, so audio is never lost if our IOProc stops.
        // Probe: leave the app alone entirely; we are only listening.
        description.muteBehavior = probe ? .unmuted : .mutedWhenTapped

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
            let stats = statsStorage
            let silent = probe
            try TapError.check(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
                    _, inputData, _, outputData, _ in
                    TapSession.render(gain: silent ? 0 : storage.pointee, stats: stats,
                                      input: inputData, output: outputData)
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
                               stats: UnsafeMutablePointer<Stats>,
                               input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)

        // Only until the tap proves itself: a scan per callback forever would be
        // wasted work on the realtime thread.
        let watchingForSilence = stats.pointee.sawAudio == 0
        var silentSamples: UInt32 = 0
        var sawAudio = false

        let paired = min(inputBuffers.count, outputBuffers.count)
        for index in 0..<paired {
            let source = inputBuffers[index]
            let destination = outputBuffers[index]
            guard let sourceData = source.mData, let destinationData = destination.mData else {
                continue
            }
            let copyBytes = min(Int(source.mDataByteSize), Int(destination.mDataByteSize))

            if watchingForSilence, !sawAudio {
                let scanned = copyBytes / MemoryLayout<Float>.size
                let src = sourceData.assumingMemoryBound(to: Float.self)
                for sample in 0..<scanned where src[sample] != 0 { sawAudio = true; break }
                if !sawAudio { silentSamples &+= UInt32(scanned) }
            }

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

        if watchingForSilence {
            if sawAudio {
                stats.pointee.sawAudio = 1
            } else {
                // Saturate rather than wrap: a probe left listening all day must
                // not flip back to "just started".
                let total = UInt64(stats.pointee.silentSamples) + UInt64(silentSamples)
                stats.pointee.silentSamples = UInt32(min(total, UInt64(UInt32.max)))
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
        statsStorage.deallocate()
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
        /// Stable across launches — the bundle ID where there is one. Settings are
        /// stored under this, not the pid, so a volume survives quitting the app.
        let settingsKey: String
        let name: String
        let icon: NSImage?
        var gainPercent: Double   // 100 == unity
        var isMuted: Bool
        var boostEnabled: Bool
        /// Our render has replaced this app's own output.
        var isControlled: Bool
        /// A probe is listening for this app's first sample before we take over.
        var isWaitingForAudio: Bool
        /// The probe has heard nothing for a while although the app says it is
        /// playing — the sign that audio-recording access is probably missing.
        var isStalled: Bool

        static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
            lhs.id == rhs.id
                && lhs.name == rhs.name
                && lhs.gainPercent == rhs.gainPercent
                && lhs.isMuted == rhs.isMuted
                && lhs.boostEnabled == rhs.boostEnabled
                && lhs.isControlled == rhs.isControlled
                && lhs.isWaitingForAudio == rhs.isWaitingForAudio
                && lhs.isStalled == rhs.isStalled
        }
    }

    static let maxBoostPercent: Double = 400

    @Published private(set) var apps: [AudioApp] = []

    private struct Settings: Codable, Equatable {
        var gainPercent: Double = 100
        var isMuted = false
        var boostEnabled = false

        var linearGain: Float { isMuted ? 0 : Float(gainPercent / 100) }
        var needsTap: Bool { isMuted || abs(gainPercent - 100) > 0.5 }
        /// Nothing worth remembering — used to drop the entry rather than store a no-op.
        var isDefault: Bool { self == Settings() }
    }

    private static let settingsDefaultsKey = "VolBoost.settings"

    /// Roughly five seconds of stereo 48 kHz. A probe that has heard nothing in
    /// that long while its process claims to be playing is worth a hint — only a
    /// hint, because a quiet call or a paused player looks exactly the same.
    private static let stalledSampleThreshold: UInt32 = 480_000

    /// Audio that belongs to an app the user knows, but is rendered by a helper
    /// process. FaceTime is the one that matters: call audio comes out of
    /// `avconferenced`, so a row labelled "avconferenced" was the only way to
    /// reach it — and the FaceTime row itself only carries ringtones.
    private static let helperProcesses: [String: (name: String, iconOwner: String)] = [
        "com.apple.avconferenced": ("FaceTime call audio", "com.apple.FaceTime"),
    ]

    private var settings: [String: Settings] = [:]
    /// Apps whose remembered volume could not be re-applied. Without this the
    /// refresh timer would retry — and re-alert — every 1.5 seconds.
    private var autoStartFailed: Set<String> = []
    private var sessions: [pid_t: TapSession] = [:]
    /// Pending "back at 100%, let the app have its own audio again" teardowns,
    /// debounced so dragging through unity mid-gesture does not glitch playback.
    private var teardownTimers: [pid_t: Timer] = [:]
    private var refreshTimer: Timer?
    /// Runs only while a probe exists, so the switch to live happens within a
    /// tenth of a second of the first sample rather than at the next slow refresh.
    private var probeTimer: Timer?
    private var hasShownPermissionAlert = false
    private var helperIcons: [String: NSImage?] = [:]
    /// Set the first time any tap delivers a sample: from then on we know the
    /// permission is granted and new sessions can go live immediately.
    private var permissionProven = false

    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var processListListener: AudioObjectPropertyListenerBlock?
    /// One listener per process object, so an app starting to play is noticed
    /// at once instead of at the next poll.
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var refreshQueued = false

    // MARK: Lifecycle

    func start() {
        loadSettings()
        refresh()
        // The listeners below do the real work; this is the safety net for
        // anything coreaudiod does not announce.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        let system = AudioObjectID(kAudioObjectSystemObject)

        var deviceAddress = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildSessions()
        }
        AudioObjectAddPropertyListenerBlock(system, &deviceAddress, .main, deviceListener)
        self.deviceListener = deviceListener

        var listAddress = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        let listListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.requestRefresh()
        }
        AudioObjectAddPropertyListenerBlock(system, &listAddress, .main, listListener)
        self.processListListener = listListener
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        probeTimer?.invalidate()
        probeTimer = nil
        for timer in teardownTimers.values { timer.invalidate() }
        teardownTimers.removeAll()
        for session in sessions.values { session.invalidate() }
        sessions.removeAll()

        let system = AudioObjectID(kAudioObjectSystemObject)
        if let deviceListener {
            var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, deviceListener)
            self.deviceListener = nil
        }
        if let processListListener {
            var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, processListListener)
            self.processListListener = nil
        }
        syncProcessListeners(with: [])
    }

    /// Coalesces a burst of notifications into one refresh on the next turn of
    /// the run loop.
    private func requestRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    private func syncProcessListeners(with objectIDs: Set<AudioObjectID>) {
        var address = propertyAddress(kAudioProcessPropertyIsRunningOutput)
        for objectID in Array(processListeners.keys) where !objectIDs.contains(objectID) {
            if let block = processListeners.removeValue(forKey: objectID) {
                // The object is usually gone by now; a failure here is expected.
                AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
            }
        }
        for objectID in objectIDs where processListeners[objectID] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.requestRefresh()
            }
            if AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block) == noErr {
                processListeners[objectID] = block
            }
        }
    }

    private func updateProbeTimer() {
        let probing = sessions.values.contains { $0.isProbe }
        if probing, probeTimer == nil {
            probeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                // Cheap check first; the full refresh only when there is news.
                if self.sessions.values.contains(where: { $0.isProbe && $0.hasDeliveredAudio }) {
                    self.refresh()
                }
            }
        } else if !probing, let probeTimer {
            probeTimer.invalidate()
            self.probeTimer = nil
        }
    }

    // MARK: Discovery

    private func refresh() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        var discovered: [AudioApp] = []
        var livePIDs: Set<pid_t> = []
        var liveKeys: Set<String> = []

        let objectIDs = readObjectIDs(AudioObjectID(kAudioObjectSystemObject),
                                      kAudioHardwarePropertyProcessObjectList)
        syncProcessListeners(with: Set(objectIDs))

        for objectID in objectIDs {
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
            let helper = bundleID.flatMap { Self.helperProcesses[$0] }
            let name = helper?.name
                ?? runningApp?.localizedName
                ?? bundleID?.split(separator: ".").last.map(String.init)
                ?? "PID \(pid)"
            let icon = helper.map { helperIcon(for: $0.iconOwner) } ?? runningApp?.icon

            // Processes without a bundle ID cannot be recognised next launch; they
            // still work for this session, they just do not persist.
            let settingsKey = bundleID ?? "pid:\(pid)"
            liveKeys.insert(settingsKey)

            let appSettings = settings[settingsKey] ?? Settings()

            // A probe that has heard audio proves both that macOS is handing us
            // this process and that audio-recording access is granted. Take over.
            if let session = sessions[pid], session.isProbe, session.hasDeliveredAudio {
                permissionProven = true
                sessions.removeValue(forKey: pid)?.invalidate()
                if appSettings.needsTap {
                    let started = startSession(for: pid, objectID: objectID, name: name,
                                               gain: appSettings.linearGain,
                                               announceFailure: false)
                    if !started { autoStartFailed.insert(settingsKey) }
                }
            }

            // A remembered volume has to be re-applied when the app comes back,
            // otherwise persisting it was pointless. Silent: the user did not ask
            // for this right now, so a failure must not interrupt them.
            if appSettings.needsTap, sessions[pid] == nil,
               !autoStartFailed.contains(settingsKey) {
                let started = startSession(for: pid, objectID: objectID,
                                           name: name, gain: appSettings.linearGain,
                                           announceFailure: false)
                if !started { autoStartFailed.insert(settingsKey) }
            }

            let session = sessions[pid]
            let probing = session?.isProbe ?? false
            let stalled = probing && isRunningOutput
                && (session?.silentSampleCount ?? 0) > Self.stalledSampleThreshold
            discovered.append(AudioApp(id: pid,
                                       objectID: objectID,
                                       settingsKey: settingsKey,
                                       name: name,
                                       icon: icon,
                                       gainPercent: appSettings.gainPercent,
                                       isMuted: appSettings.isMuted,
                                       boostEnabled: appSettings.boostEnabled,
                                       isControlled: session != nil && !probing,
                                       isWaitingForAudio: probing,
                                       isStalled: stalled))
        }

        // Tear down pipelines for processes that are gone. Their settings stay:
        // that is the whole point of keying them by bundle ID.
        for pid in Array(sessions.keys) where !livePIDs.contains(pid) {
            sessions.removeValue(forKey: pid)?.invalidate()
            teardownTimers.removeValue(forKey: pid)?.invalidate()
        }

        // A failure belongs to the run of the app that hit it. Once that app is
        // gone, its next launch deserves a fresh attempt.
        autoStartFailed.formIntersection(liveKeys)

        updateProbeTimer()

        let sorted = discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if sorted != apps { apps = sorted }
    }

    // MARK: Control

    func setGainPercent(_ percent: Double, for app: AudioApp) {
        var appSettings = settings[app.settingsKey] ?? Settings()
        appSettings.gainPercent = min(max(percent, 0), Self.maxBoostPercent)
        apply(appSettings, to: app)
    }

    func toggleMute(for app: AudioApp) {
        var appSettings = settings[app.settingsKey] ?? Settings()
        appSettings.isMuted.toggle()
        apply(appSettings, to: app)
    }

    func setBoostEnabled(_ enabled: Bool, for app: AudioApp) {
        var appSettings = settings[app.settingsKey] ?? Settings()
        appSettings.boostEnabled = enabled
        if !enabled { appSettings.gainPercent = min(appSettings.gainPercent, 100) }
        apply(appSettings, to: app)
    }

    private func apply(_ appSettings: Settings, to app: AudioApp) {
        // An explicit adjustment is a fresh mandate: allow retrying a tap that
        // failed to auto-start earlier.
        autoStartFailed.remove(app.settingsKey)

        // Storing a default would resurrect unity gain on every future launch for
        // no reason, so back at 100% and unmuted means forget the app entirely.
        if appSettings.isDefault {
            settings.removeValue(forKey: app.settingsKey)
        } else {
            settings[app.settingsKey] = appSettings
        }
        persistSettings()

        if appSettings.needsTap {
            cancelTeardown(app.id)
            if let session = sessions[app.id] {
                session.gain = appSettings.linearGain
            } else {
                startSession(for: app, gain: appSettings.linearGain)
            }
        } else if let session = sessions[app.id] {
            session.gain = appSettings.linearGain
            if session.isProbe {
                // Nothing to hand back — a probe never took the app's audio away.
                sessions.removeValue(forKey: app.id)?.invalidate()
            } else {
                // Unity gain is a passthrough memcpy, so the pipeline can stay
                // while the gesture is still moving — tearing the aggregate device
                // down mid-drag would glitch the audio. Once the value settles at
                // 100%, though, hand the app back its own output.
                scheduleTeardown(app.id)
            }
        }
        refresh()
    }

    @discardableResult
    private func startSession(for app: AudioApp, gain: Float) -> Bool {
        startSession(for: app.id, objectID: app.objectID, name: app.name,
                     gain: gain, announceFailure: true)
    }

    @discardableResult
    private func startSession(for pid: pid_t, objectID: AudioObjectID, name: String,
                              gain: Float, announceFailure: Bool) -> Bool {
        guard let outputUID = defaultOutputDeviceUID() else { return false }
        do {
            sessions[pid] = try TapSession(processObjectID: objectID,
                                           pid: pid,
                                           outputDeviceUID: outputUID,
                                           gain: gain,
                                           probe: !permissionProven)
            updateProbeTimer()
            return true
        } catch let error as TapError {
            // The permission alert is worth showing either way — it is shown once
            // in the app's lifetime and explains why nothing is happening.
            if error.looksLikePermissionDenial {
                presentPermissionAlert()
            } else if announceFailure {
                presentFailureAlert(error, appName: name)
            }
            return false
        } catch {
            // Leave the stored setting alone: a transient failure should not
            // silently discard a volume the user chose.
            return false
        }
    }

    /// Give the app its own (unmuted) output back once the slider has settled at
    /// 100% for long enough that this is clearly not a drag passing through.
    private func scheduleTeardown(_ pid: pid_t) {
        cancelTeardown(pid)
        teardownTimers[pid] = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            self.teardownTimers.removeValue(forKey: pid)
            // Re-check: the user may have moved off 100% again while we waited.
            if let app = self.apps.first(where: { $0.id == pid }),
               (self.settings[app.settingsKey] ?? Settings()).needsTap { return }
            self.sessions.removeValue(forKey: pid)?.invalidate()
            self.refresh()
        }
    }

    private func cancelTeardown(_ pid: pid_t) {
        teardownTimers.removeValue(forKey: pid)?.invalidate()
    }

    func openAudioAccessSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func helperIcon(for bundleID: String) -> NSImage? {
        if let cached = helperIcons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        helperIcons[bundleID] = icon
        return icon
    }

    // MARK: Persistence

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsDefaultsKey),
              let stored = try? JSONDecoder().decode([String: Settings].self, from: data)
        else { return }
        settings = stored
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsDefaultsKey)
    }

    /// Rebuild every live pipeline against the new default output device.
    private func rebuildSessions() {
        let controlled = sessions.keys.compactMap { pid in apps.first { $0.id == pid } }
        for session in sessions.values { session.invalidate() }
        sessions.removeAll()
        for app in controlled {
            let appSettings = settings[app.settingsKey] ?? Settings()
            guard appSettings.needsTap else { continue }
            // Silent: the user changed an output device, not a slider, and one
            // alert per controlled app would be a pile-up.
            let started = startSession(for: app.id, objectID: app.objectID, name: app.name,
                                       gain: appSettings.linearGain, announceFailure: false)
            if !started { autoStartFailed.insert(app.settingsKey) }
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
            + "which is how VolBoost changes that app's volume.\n\n"
            + "Allow it, then move the slider again. Each rebuild of VolBoost is re-signed, so "
            + "macOS treats it as a new app and asks again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAudioAccessSettings()
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
