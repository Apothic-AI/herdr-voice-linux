// swift-tools-version:5.10
import PackageDescription

// The app is one target with two platform halves. Everything portable — the wires, the Herdr tools, the orb's
// mood maths, the window-pinning decisions — lives in HerdrVoiceCore and builds everywhere. The executable's
// per-platform pieces are whole files rather than #if soup inside them: Audio, Orb, Hotkey, WindowTracker, Setup
// and AppHost each have an AppKit implementation and an X11 one, and only the matching directory is compiled.
#if os(macOS)
let excludedPlatformDirectory = "Linux"
let nativeTargets: [Target] = []
let nativeDependencies: [Target.Dependency] = []
#else
let excludedPlatformDirectory = "macOS"
// Linux reaches the system libraries through small systemLibrary shims: PortAudio for capture and playback,
// Xlib for the orb window and global hotkeys, Cairo for drawing it.
let nativeTargets: [Target] = [
    .systemLibrary(name: "CPortAudio", path: "Sources/CPortAudio", pkgConfig: "portaudio-2.0",
                   providers: [.apt(["portaudio19-dev"])]),
    .systemLibrary(name: "CX11", path: "Sources/CX11", pkgConfig: "x11",
                   providers: [.apt(["libx11-dev", "libxrender-dev"])]),
    .systemLibrary(name: "CCairo", path: "Sources/CCairo", pkgConfig: "cairo",
                   providers: [.apt(["libcairo2-dev"])]),
]
let nativeDependencies: [Target.Dependency] = ["CPortAudio", "CX11", "CCairo"]
#endif

let package = Package(
    name: "herdr-voice",
    platforms: [.macOS(.v14)],
    targets: nativeTargets + [
        .target(name: "HerdrVoiceCore"),
        .executableTarget(
            name: "herdr-voice",
            dependencies: ["HerdrVoiceCore"] + nativeDependencies,
            exclude: [excludedPlatformDirectory]
        ),
        .testTarget(name: "HerdrVoiceTests", dependencies: ["HerdrVoiceCore"]),
    ]
)
