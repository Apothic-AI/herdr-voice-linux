// swift-tools-version:5.10
import PackageDescription

// The app is one target with two platform halves. Everything portable — the wires, the Herdr tools, the orb's
// mood maths, the window-pinning decisions — lives in HerdrVoiceCore and builds everywhere. The executable's
// per-platform pieces are whole files rather than #if soup inside them: Audio, Orb, Hotkey, WindowTracker, Setup
// and AppHost each have an AppKit implementation and an X11 one, and only the matching directory is compiled.
let platformSources: [String] = {
    #if os(macOS)
    return ["macOS"]
    #else
    return ["Linux"]
    #endif
}()

let package = Package(
    name: "herdr-voice",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HerdrVoiceCore"),
        .executableTarget(
            name: "herdr-voice",
            dependencies: ["HerdrVoiceCore"],
            exclude: platformSources == ["macOS"] ? ["Linux"] : ["macOS"]
        ),
        .testTarget(name: "HerdrVoiceTests", dependencies: ["HerdrVoiceCore"]),
    ]
)
