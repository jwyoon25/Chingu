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
            path: "Sources/Chingu"
            // Entry point is the top-level code in main.swift (we drive NSApplication
            // ourselves — no @main App lifecycle).
        )
    ]
)
