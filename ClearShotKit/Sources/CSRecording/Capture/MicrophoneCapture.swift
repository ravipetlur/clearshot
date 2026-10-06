import AVFoundation
import CoreMedia
import CSCapture
import CSCore
import Foundation
import Synchronization

/// Why a microphone can't be used.
public enum MicrophoneError: Error, Equatable {
    /// No audio input has this unique ID now (unplugged).
    case deviceNotFound
    /// The capture session couldn't take the device (no permission, or the device refused).
    case cannotUseDevice
    /// The session didn't start running.
    case failedToStart
}

/// Records one microphone through `AVCaptureSession` as mono 32-bit float PCM at 48 kHz, warm from Ready's meter into
/// the recording. ScreenCaptureKit's own microphone capture isn't used: a microphone that failed to start would fail
/// the whole stream (−3820), and a microphone failure must never stop the screen recording.
///
/// Two private serial queues: `startRunning` and `stopRunning` (which block) run on the control queue, and the buffers
/// arrive on the sample queue, so a stop never waits on the queue that delivers. Each buffer updates `levelDecibels`;
/// while forwarding, it is retimed into the recording stream's clock and handed to the handler, still on the sample
/// queue (the app hops it onto the writer's queue).
public final class MicrophoneCapture: @unchecked Sendable {
    private let controlQueue = DispatchQueue(label: CSCore.identifier("microphone.control"), qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: CSCore.identifier("microphone.samples"), qos: .userInitiated)
    /// Started and stopped on `controlQueue`; the sample queue only reads its `synchronizationClock`.
    private let session: AVCaptureSession
    private let receiver: SampleReceiver
    /// Whether a missing synchronization clock was logged; confined to `sampleQueue`.
    private var loggedMissingClock = false
    // Touched only in `init` and `deinit`.
    private var observers: [any NSObjectProtocol] = []

    private let name: String
    private let level = Mutex(AudioLevel.floor)
    private let forwarding = Mutex<Forwarding?>(nil)
    private let disconnectHandler = Mutex<(@Sendable () -> Void)?>(nil)
    private let hasDisconnected = Mutex(false)

    private struct Forwarding: Sendable {
        let handler: @Sendable (CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) -> Void
        let stream: ScreenRecordingStream?
    }

    /// Sets up a session for the audio input with this unique ID. Throws `MicrophoneError.deviceNotFound` when it is
    /// gone, `.cannotUseDevice` when the session can't take it. Ask for the microphone permission first: with it
    /// undecided, making the device input can show the system's prompt.
    public init(deviceID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID), device.hasMediaType(.audio) else {
            throw MicrophoneError.deviceNotFound
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            Log.recording.error("Microphone \(device.localizedName): \(error.localizedDescription)")
            throw MicrophoneError.cannotUseDevice
        }
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicrophoneError.cannotUseDevice
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        self.session = session
        name = device.localizedName
        receiver = SampleReceiver()
        receiver.owner = self
        output.setSampleBufferDelegate(receiver, queue: sampleQueue)

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device,
                               queue: nil) { [weak self] _ in
                self?.disconnect("disconnected")
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                               queue: nil) { [weak self] notice in
                let error = notice.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.disconnect("runtime error \(error.map { "\($0.code): \($0.localizedDescription)" } ?? "")")
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        // Normally stopped already; never leave the microphone open.
        nonisolated(unsafe) let session = session
        controlQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    /// The RMS of the latest buffer, in dBFS (`AudioLevel.floor` before the first).
    public var levelDecibels: Float {
        level.withLock { $0 }
    }

    /// Called once, from any thread, when the device is disconnected or the session fails while running. Set it before
    /// `start`.
    public var onDisconnect: (@Sendable () -> Void)? {
        get { disconnectHandler.withLock { $0 } }
        set { disconnectHandler.withLock { $0 = newValue } }
    }

    /// The device was disconnected, or the session failed, since it was set up, whether or not `onDisconnect` was set
    /// then. A new owner sets `onDisconnect` first and reads this after, so a disconnection in between is never missed.
    public var isDisconnected: Bool {
        hasDisconnected.withLock { $0 }
    }

    /// Starts the session off the caller's thread. Throws `MicrophoneError.failedToStart` when it doesn't run.
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            controlQueue.async { [self] in
                if !session.isRunning {
                    session.startRunning()
                }
                continuation.resume(with: session.isRunning ? .success(()) : .failure(MicrophoneError.failedToStart))
            }
        }
    }

    /// Stops the session and waits until it has.
    public func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controlQueue.async { [self] in
                if session.isRunning {
                    session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    /// Sends each buffer, retimed into the clock `stream` reads, to `handler` (nil stops sending). Buffers are dropped
    /// until the stream has started; without a stream they keep the session's timing. The handler runs on the
    /// microphone's sample queue.
    public func forward(to handler: (@Sendable (CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) -> Void)?,
                        clockOf stream: ScreenRecordingStream?) {
        forwarding.withLock { $0 = handler.map { Forwarding(handler: $0, stream: stream) } }
    }

    // MARK: Private

    /// One buffer from the session, on `sampleQueue`.
    fileprivate func receive(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(sampleQueue))
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        if let decibels = Self.decibels(of: sampleBuffer) {
            level.withLock { $0 = decibels }
        }
        guard let forwarding = forwarding.withLock({ $0 }) else { return }
        var offset = CMTime.zero
        if let stream = forwarding.stream {
            let time = sampleBuffer.presentationTimeStamp
            // Looked up again for every buffer, so a clock that comes late is picked up.
            guard let clock = session.synchronizationClock else {
                if !loggedMissingClock {
                    loggedMissingClock = true
                    Log.recording.warning("Microphone \(name): the session has no synchronization clock yet; "
                        + "its buffers aren't forwarded until it has one")
                }
                return
            }
            // Nil until the stream has started.
            guard let converted = stream.streamTime(converting: time, from: clock) else { return }
            offset = converted - time
        }
        do {
            // A buffer the session handed over, or a new copy: nothing else here refers to it.
            nonisolated(unsafe) let retimed = offset == .zero ? sampleBuffer : try sampleBuffer.moved(by: offset)
            forwarding.handler(CMReadySampleBuffer(unsafeBuffer: retimed))
        } catch {
            Log.recording.debug("Microphone \(name): couldn't retime a buffer: \(error.localizedDescription)")
        }
    }

    private func disconnect(_ reason: String) {
        let first = hasDisconnected.withLock { disconnected -> Bool in
            defer { disconnected = true }
            return !disconnected
        }
        guard first else { return }
        Log.recording.warning("Microphone \(name): \(reason)")
        onDisconnect?()
    }

    /// The RMS of a float PCM buffer in dBFS (the loudest channel buffer), or nil when it isn't 32-bit float.
    private static func decibels(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return nil }
        return try? sampleBuffer.withAudioBufferList { buffers, _ in
            buffers.map { buffer -> Float in
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard let data = buffer.mData, count > 0 else { return AudioLevel.floor }
                return AudioLevel.rmsDecibels(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            }.max() ?? AudioLevel.floor
        }
    }
}

/// The session's sample buffer delegate, handing each buffer to its microphone on the sample queue. It holds the
/// microphone weakly, so the output keeping it never keeps the microphone.
private final class SampleReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Set in the microphone's `init`, before the output delivers anything.
    weak var owner: MicrophoneCapture?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        owner?.receive(sampleBuffer)
    }
}
