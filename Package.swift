// swift-tools-version: 5.9
// Package.swift — OpenDicomViewer
// Licensed under the MIT License. See LICENSE for details.

import PackageDescription

let package = Package(
    name: "OpenDicomViewer",
    // NOTE (iOS port): `.iOS(.v17)` was added here in an earlier pass, ahead
    // of actually creating the Xcode iOS App target described in
    // docs/iOS-Build.md. Pulled back out because it had an immediate, real
    // side effect on the macOS build: declaring iOS support makes Xcode
    // offer a "My Mac (Mac Catalyst)" destination for this scheme, and
    // DCMTKHelper.mm's NSImage(cgImage:size:) calls are hard errors under
    // Catalyst ("not available on macCatalyst") -- Catalyst was never an
    // intended target here, just an unwanted side door that opened once iOS
    // was declared with nothing yet consuming it. Add `.iOS(.v17)` back at
    // the same time an actual iOS App target is created and wired up (step 2
    // of docs/iOS-Build.md), so any platform-declaration side effects like
    // this one surface and get fixed in that same pass instead of sitting
    // latent and confusing the macOS build in the meantime.
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // macOS command-line/scripted build product, used unchanged by
        // scripts/package_app.sh (`swift build` -> .build/release/OpenDicomViewer).
        .executable(name: "OpenDicomViewer", targets: ["OpenDicomViewer"]),
        // Shared library product. A real Xcode iOS "App" target (created and
        // built on macOS with Xcode -- not something this sandbox can produce)
        // adds this package as a local package dependency and links against
        // this product to get the whole viewer minus a platform entry point.
        // See docs/iOS-Build.md.
        .library(name: "OpenDicomViewerCore", targets: ["OpenDicomViewerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.12.0")
    ],
    targets: [
        .target(
            name: "DCMTKWrapper",
            dependencies: [],
            // NOTE (iOS port): these settings are unconditional/macOS-only in
            // effect, same as before this package was restructured for iOS --
            // libs/dcmtk and libs/openjpeg only contain macOS arm64 static
            // libraries today, and this target can't build for iOS at all yet
            // regardless (DCMTKHelper.mm itself is still hardcoded to
            // AppKit/NSImage -- see docs/iOS-Build.md). An earlier version of
            // this file wrapped every setting below in `.when(platforms:
            // [.macOS])`, intending to prepare for iOS-conditioned settings
            // being added later, but that broke the macOS Xcode build (a
            // `.headerSearchPath` gated this way stopped resolving even
            // though the target file it pointed at genuinely existed on disk)
            // and was reverted. When iOS support is actually implemented,
            // linking iOS-built DCMTK/OpenJPEG will most likely go through a
            // `.binaryTarget` XCFramework instead of conditioning these
            // existing settings, so nothing is lost by reverting.
            cSettings: [
                .headerSearchPath("../../libs/dcmtk/include"),
                .headerSearchPath("../../libs/openjpeg/include/openjpeg-2.5")
            ],
            cxxSettings: [
                .headerSearchPath("../../libs/dcmtk/include"),
                .headerSearchPath("../../libs/openjpeg/include/openjpeg-2.5"),
                .define("DCMTK_BUILD_IN_PROGRESS")
            ],
            linkerSettings: [
                .unsafeFlags(["-Llibs/dcmtk/lib", "-Llibs/openjpeg/lib"]),
                .linkedLibrary("dcmimage"),
                .linkedLibrary("dcmimgle"),
                .linkedLibrary("dcmdata"),
                .linkedLibrary("oflog"),
                .linkedLibrary("ofstd"),
                .linkedLibrary("dcmjpeg"),
                .linkedLibrary("dcmjpls"),
                .linkedLibrary("dcmtkcharls"),
                .linkedLibrary("ijg8"),
                .linkedLibrary("ijg12"),
                .linkedLibrary("ijg16"),
                .linkedLibrary("oficonv"),
                .linkedLibrary("z"),
                .linkedLibrary("openjp2")
            ]
        ),
        // Shared library target: every view, model, and rendering type, plus
        // the shared `OpenDicomViewerCoreApp` SwiftUI App scene. Consumed by
        // both the macOS executable shim below and (eventually) an iOS Xcode
        // App target via the OpenDicomViewerCore product.
        .target(
            name: "OpenDicomViewerCore",
            dependencies: ["DCMTKWrapper"],
            path: "Sources/OpenDicomViewer"
        ),
        // Thin macOS-only executable shim: a single main.swift that forwards
        // to OpenDicomViewerCoreApp.main(). Kept as its own target/product
        // (named "OpenDicomViewer" for backwards compatibility with
        // scripts/package_app.sh) because a SwiftPM `.executableTarget` is a
        // macOS/Linux/Windows-only concept -- it has no iOS equivalent.
        .executableTarget(
            name: "OpenDicomViewer",
            dependencies: ["OpenDicomViewerCore"],
            path: "Sources/OpenDicomViewerMacApp"
        ),
        .testTarget(
            name: "OpenDicomViewerTests",
            dependencies: [
                "OpenDicomViewerCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
    ]
)
