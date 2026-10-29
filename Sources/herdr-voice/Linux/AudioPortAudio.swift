import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// PortAudio, bound at run time.
///
/// The package has no `CPortAudio` system-library target and no linker settings, and `Package.swift` belongs to the
/// build seam rather than to this file, so `libportaudio.so.2` is loaded with `dlopen` and the dozen symbols the
/// audio path needs are resolved once at start-up. Everything the callbacks reach is preallocated, so the binding
/// itself adds no work to the real-time path.
///
/// The struct layouts below are the LP64 C ABI from `/usr/include/portaudio.h`, read field by field at explicit
/// offsets so a Swift layout change can never silently shift them.
final class PortAudio {
    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    // PortAudio constants (portaudio.h).
    static let float32: UInt = 0x0000_0001
    static let noFlag: UInt = 0
    static let noError: Int32 = 0
    static let continueStream: Int32 = 0

    /// `typedef int PaStreamCallback(const void*, void*, unsigned long, const PaStreamCallbackTimeInfo*,
    /// PaStreamCallbackFlags, void*)` — note `PaStreamCallbackFlags` is an `unsigned long`, not an `unsigned int`.
    typealias StreamCallback = @convention(c) (
        UnsafeRawPointer?, UnsafeMutableRawPointer?, UInt, UnsafeRawPointer?, UInt, UnsafeMutableRawPointer?
    ) -> Int32

    /// `PaStreamParameters` on LP64: `device` int@0, `channelCount` int@4, `sampleFormat` unsigned long@8,
    /// `suggestedLatency` double@16, `hostApiSpecificStreamInfo` void*@24 — 32 bytes, written by
    /// `withStreamParameters` because a Swift struct cannot appear in a `@convention(c)` signature.
    static let streamParametersSize = 32

    final class Device {
        let index: Int32
        let name: String
        let maxInputChannels: Int
        let maxOutputChannels: Int
        let defaultSampleRate: Double

        init(index: Int32, name: String, maxInputChannels: Int, maxOutputChannels: Int, defaultSampleRate: Double) {
            self.index = index
            self.name = name
            self.maxInputChannels = maxInputChannels
            self.maxOutputChannels = maxOutputChannels
            self.defaultSampleRate = defaultSampleRate
        }

        /// A PipeWire/PulseAudio `module-echo-cancel` source, if the platform exposes one to PortAudio. Its name is
        /// matched rather than its host API because the module names the node `<sink>.echo-cancel`.
        var isPlatformEchoCancel: Bool {
            let lower = name.lowercased()
            return lower.contains("echo-cancel") || lower.contains("echocancel")
        }

        /// A monitor of an output, or a hardware loopback, carries what is being *played* rather than what the room
        /// sounds like. A voice app that captures one hears its own voice and feeds it back: a loud tone whose pitch
        /// tracks the microphone gain. Never choose one unless it was asked for by name.
        var isFeedbackProne: Bool {
            let lower = name.lowercased()
            return lower.hasSuffix(".monitor") || lower.contains("monitor of") || lower.contains("aloop")
        }
    }

    let version: String

    private let handle: UnsafeMutableRawPointer
    private let pInitialize: @convention(c) () -> Int32
    private let pTerminate: @convention(c) () -> Int32
    private let pGetErrorText: @convention(c) (Int32) -> UnsafePointer<CChar>?
    private let pGetDeviceCount: @convention(c) () -> Int32
    private let pGetDeviceInfo: @convention(c) (Int32) -> UnsafeMutableRawPointer?
    private let pGetDefaultInputDevice: @convention(c) () -> Int32
    private let pGetDefaultOutputDevice: @convention(c) () -> Int32
    private let pOpenStream: @convention(c) (
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
        UnsafeRawPointer?, UnsafeRawPointer?, Double, UInt, UInt, UnsafeRawPointer?, UnsafeMutableRawPointer?
    ) -> Int32
    private let pStartStream: @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private let pStopStream: @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private let pAbortStream: @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private let pCloseStream: @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private let pGetStreamInfo: @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

    /// nil when libportaudio is not installed at all; `start()` turns that into a readable error.
    static let shared: PortAudio? = {
        for name in ["libportaudio.so.2", "libportaudio.so"] {
            if let handle = dlopen(name, RTLD_NOW | RTLD_LOCAL) {
                if let library = PortAudio(handle: handle) { return library }
                dlclose(handle)
            }
        }
        return nil
    }()

    private init?(handle: UnsafeMutableRawPointer) {
        guard
            let initialize = PortAudio.symbol(handle, "Pa_Initialize", (@convention(c) () -> Int32).self),
            let terminate = PortAudio.symbol(handle, "Pa_Terminate", (@convention(c) () -> Int32).self),
            let errorText = PortAudio.symbol(handle, "Pa_GetErrorText", (@convention(c) (Int32) -> UnsafePointer<CChar>?).self),
            let deviceCount = PortAudio.symbol(handle, "Pa_GetDeviceCount", (@convention(c) () -> Int32).self),
            let deviceInfo = PortAudio.symbol(handle, "Pa_GetDeviceInfo", (@convention(c) (Int32) -> UnsafeMutableRawPointer?).self),
            let defaultIn = PortAudio.symbol(handle, "Pa_GetDefaultInputDevice", (@convention(c) () -> Int32).self),
            let defaultOut = PortAudio.symbol(handle, "Pa_GetDefaultOutputDevice", (@convention(c) () -> Int32).self),
            let openStream = PortAudio.symbol(handle, "Pa_OpenStream", (@convention(c) (
                UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                UnsafeRawPointer?, UnsafeRawPointer?, Double, UInt, UInt, UnsafeRawPointer?, UnsafeMutableRawPointer?
            ) -> Int32).self),
            let startStream = PortAudio.symbol(handle, "Pa_StartStream", (@convention(c) (UnsafeMutableRawPointer?) -> Int32).self),
            let stopStream = PortAudio.symbol(handle, "Pa_StopStream", (@convention(c) (UnsafeMutableRawPointer?) -> Int32).self),
            let abortStream = PortAudio.symbol(handle, "Pa_AbortStream", (@convention(c) (UnsafeMutableRawPointer?) -> Int32).self),
            let closeStream = PortAudio.symbol(handle, "Pa_CloseStream", (@convention(c) (UnsafeMutableRawPointer?) -> Int32).self),
            let streamInfo = PortAudio.symbol(handle, "Pa_GetStreamInfo", (@convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?).self),
            let versionText = PortAudio.symbol(handle, "Pa_GetVersionText", (@convention(c) () -> UnsafePointer<CChar>?).self)
        else { return nil }

        self.handle = handle
        pInitialize = initialize
        pTerminate = terminate
        pGetErrorText = errorText
        pGetDeviceCount = deviceCount
        pGetDeviceInfo = deviceInfo
        pGetDefaultInputDevice = defaultIn
        pGetDefaultOutputDevice = defaultOut
        pOpenStream = openStream
        pStartStream = startStream
        pStopStream = stopStream
        pAbortStream = abortStream
        pCloseStream = closeStream
        pGetStreamInfo = streamInfo
        if let text = versionText() {
            version = String(cString: text)
        } else {
            version = "unknown"
        }
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _ type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    deinit {
        pTerminate()
        dlclose(handle)
    }

    // MARK: - Lifecycle

    enum Initialization: Equatable {
        case ready
        case failed(String)
    }

    /// `Pa_Initialize` is not thread-safe and must be paired with `terminate()`.
    func initialize() -> Initialization {
        let error = pInitialize()
        return error == PortAudio.noError ? .ready : .failed(errorText(error))
    }

    func terminate() { _ = pTerminate() }

    func errorText(_ error: Int32) -> String {
        guard let text = pGetErrorText(error) else { return "PortAudio error \(error)" }
        return String(cString: text)
    }

    // MARK: - Devices

    var deviceCount: Int { Int(max(0, pGetDeviceCount())) }

    func device(_ index: Int32) -> Device? {
        guard index >= 0, let raw = pGetDeviceInfo(index) else { return nil }
        // PaDeviceInfo on LP64: structVersion:int@0, name:char*@8, hostApi:int@16, maxInputChannels:int@20,
        // maxOutputChannels:int@24, four PaTime doubles@32..64, defaultSampleRate:double@64.
        let nameWord = raw.load(fromByteOffset: 8, as: UInt.self)
        let name = nameWord == 0
            ? "?"
            : String(cString: UnsafeRawPointer(bitPattern: nameWord)!.assumingMemoryBound(to: CChar.self))
        let maxIn = Int(raw.load(fromByteOffset: 20, as: Int32.self))
        let maxOut = Int(raw.load(fromByteOffset: 24, as: Int32.self))
        let rate = raw.load(fromByteOffset: 64, as: Double.self)
        // A rate outside these bounds means the layout above is not what this library was built with.
        guard rate >= 4000, rate <= 384_000 else { return nil }
        return Device(index: index, name: name, maxInputChannels: maxIn, maxOutputChannels: maxOut, defaultSampleRate: rate)
    }

    func devices() -> [Device] { (0..<deviceCount).compactMap { device(Int32($0)) } }

    var defaultInputDevice: Int32 { pGetDefaultInputDevice() }
    var defaultOutputDevice: Int32 { pGetDefaultOutputDevice() }

    /// First device that can carry `channels` in the requested direction and whose name contains `match`.
    func device(matching match: String, input: Bool) -> Device? {
        let needle = match.lowercased()
        return devices().first { device in
            let usable = input ? device.maxInputChannels > 0 : device.maxOutputChannels > 0
            return usable && device.name.lowercased().contains(needle)
        }
    }

    // MARK: - Streams

    /// Opens one mono float32 stream. PortAudio reports failures through its return code, which the caller turns
    /// into a message that says which device it was trying to use.
    func open(
        input: Bool,
        device: Int32,
        rate: Double,
        framesPerBuffer: UInt,
        latency: Double,
        callback: StreamCallback,
        userData: UnsafeMutableRawPointer
    ) -> (stream: UnsafeMutableRawPointer?, error: String?) {
        let parameters = UnsafeMutableRawPointer.allocate(byteCount: PortAudio.streamParametersSize, alignment: 8)
        defer { parameters.deallocate() }
        memset(parameters, 0, PortAudio.streamParametersSize)
        parameters.storeBytes(of: device, toByteOffset: 0, as: Int32.self)
        parameters.storeBytes(of: Int32(1), toByteOffset: 4, as: Int32.self)
        parameters.storeBytes(of: PortAudio.float32, toByteOffset: 8, as: UInt.self)
        parameters.storeBytes(of: latency, toByteOffset: 16, as: Double.self)
        var stream: UnsafeMutableRawPointer?
        // A C function pointer is not ObjC-representable, so PortAudio's callback slot is typed as a raw pointer.
        let callbackPointer = unsafeBitCast(callback, to: UnsafeRawPointer.self)
        let error: Int32 = input
            ? pOpenStream(&stream, UnsafeRawPointer(parameters), nil, rate, framesPerBuffer, PortAudio.noFlag, callbackPointer, userData)
            : pOpenStream(&stream, nil, UnsafeRawPointer(parameters), rate, framesPerBuffer, PortAudio.noFlag, callbackPointer, userData)
        guard error == PortAudio.noError, stream != nil else {
            return (nil, errorText(error))
        }
        return (stream, nil)
    }

    struct StreamInfo {
        let inputLatency: Double
        let outputLatency: Double
        let sampleRate: Double
    }

    func streamInfo(_ stream: UnsafeMutableRawPointer) -> StreamInfo? {
        guard let raw = pGetStreamInfo(stream) else { return nil }
        // PaStreamInfo: structVersion:int@0, inputLatency@8, outputLatency@16, sampleRate@24.
        return StreamInfo(
            inputLatency: raw.load(fromByteOffset: 8, as: Double.self),
            outputLatency: raw.load(fromByteOffset: 16, as: Double.self),
            sampleRate: raw.load(fromByteOffset: 24, as: Double.self)
        )
    }

    func start(_ stream: UnsafeMutableRawPointer) -> String? {
        let error = pStartStream(stream)
        return error == PortAudio.noError ? nil : errorText(error)
    }

    /// Stops, waiting for the callback to return. An aborted stream drops its buffered frames instead.
    func stop(_ stream: UnsafeMutableRawPointer, abort: Bool) {
        _ = abort ? pAbortStream(stream) : pStopStream(stream)
    }

    func close(_ stream: UnsafeMutableRawPointer) {
        _ = pCloseStream(stream)
    }
}
