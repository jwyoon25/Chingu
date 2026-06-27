// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chingu",
    platforms: [
        // ScreenCaptureKit (CP2) and the modern SwiftUI/AppKit APIs we use need a
        // recent deployment target. Bump if CP2+ requires more.
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Chingu",
            path: "Sources/Chingu",
            // Info.plist is embedded via the linker (below), not compiled/bundled —
            // exclude it so SwiftPM doesn't warn about an unhandled file.
            exclude: ["Info.plist"],
            // CP4 (speech): embed an Info.plist into the binary's __TEXT,__info_plist
            // section so macOS TCC can read NSMicrophoneUsageDescription. A bare SwiftPM
            // executable has no app bundle, so without this the first microphone request
            // hard-crashes (not just "denied"). See docs/CP4-SPEC.md §4.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Chingu/Info.plist",
                ])
            ]
            // Entry point is the top-level code in main.swift (we drive NSApplication
            // ourselves — no @main App lifecycle).
        )
    ]
)
