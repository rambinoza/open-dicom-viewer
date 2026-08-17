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
        // XCFrameworks cross-compiled for iOS device + Simulator (arm64) by
        // scripts/setup_native_deps_ios.sh -- see docs/iOS-Build.md section 5.
        // Declared as their own binaryTargets rather than trying to extend
        // DCMTKWrapper's existing unsafeFlags-based -L/-l linking (below) to
        // iOS, since unsafeFlags aren't usable by a package consumed as a
        // dependency the way an iOS Xcode App target consumes this one --
        // XCFrameworks/binaryTargets are SwiftPM's supported mechanism for
        // that. Each is wired in below as an iOS-only dependency of
        // DCMTKWrapper via `.when(platforms: [.iOS])`. Referencing `.iOS` in
        // a dependency condition does NOT require iOS to be listed in this
        // file's top-level `platforms:` array below (that array only
        // controls minimum deployment targets / offered Xcode destinations)
        // -- so this wiring is deliberately inert until iOS is actually
        // added to `platforms:` and a real Xcode iOS App target exists to
        // consume it (docs/iOS-Build.md steps 0-3). That's intentional: only
        // add `.iOS(.v17)` back to `platforms:` in that same sitting, per the
        // NOTE above `platforms:` below, and only once DCMTKHelper.mm's
        // AppKit-only code (see docs/iOS-Build.md "Known blockers") has
        // actually been fixed to compile for iOS too -- these binaryTargets
        // alone don't make DCMTKWrapper's *source* compile for iOS yet.
        .binaryTarget(name: "DcmdataXCFramework", path: "libs/xcframeworks/dcmdata.xcframework"),
        .binaryTarget(name: "DcmimageXCFramework", path: "libs/xcframeworks/dcmimage.xcframework"),
        .binaryTarget(name: "DcmimgleXCFramework", path: "libs/xcframeworks/dcmimgle.xcframework"),
        .binaryTarget(name: "DcmjpegXCFramework", path: "libs/xcframeworks/dcmjpeg.xcframework"),
        .binaryTarget(name: "DcmjplsXCFramework", path: "libs/xcframeworks/dcmjpls.xcframework"),
        .binaryTarget(name: "DcmtkcharlsXCFramework", path: "libs/xcframeworks/dcmtkcharls.xcframework"),
        .binaryTarget(name: "Ijg8XCFramework", path: "libs/xcframeworks/ijg8.xcframework"),
        .binaryTarget(name: "Ijg12XCFramework", path: "libs/xcframeworks/ijg12.xcframework"),
        .binaryTarget(name: "Ijg16XCFramework", path: "libs/xcframeworks/ijg16.xcframework"),
        .binaryTarget(name: "OficonvXCFramework", path: "libs/xcframeworks/oficonv.xcframework"),
        .binaryTarget(name: "OflogXCFramework", path: "libs/xcframeworks/oflog.xcframework"),
        .binaryTarget(name: "OfstdXCFramework", path: "libs/xcframeworks/ofstd.xcframework"),
        .binaryTarget(name: "Openjp2XCFramework", path: "libs/xcframeworks/openjp2.xcframework"),

        .target(
            name: "DCMTKWrapper",
            dependencies: [
                .target(name: "DcmdataXCFramework", condition: .when(platforms: [.iOS])),
                .target(name: "DcmimageXCFramework", condition: .when(platforms: [.iOS])),
                .target(name: "DcmimgleXCFramework", condition: .when(platforms: [.iOS])),
                .target(name: "DcmjpegXCFramework", condition: .when(platforms: [.iOS])),
                .target(name: "DcmjplsXCFramework", condition: .when(platforms: [.iOS])),
                .target(name: "DcmtkcharlsXCFramework", condition: .when(platforms: [.iOS])),
                .target(name: "Ijg8XCFramework", condition: .when(platforms: [.iOS])),
                .target(name: "Ijg12XCFramework", condition: .when(platforms: [.iOS])),
                .target(name: "Ijg16XCFramework", condition: .when(platforms: [.iOS])),
                .target(name: "OficonvXCFramework", condition: .when(platforms: [.iOS])),
                .target(name: "OflogXCFramework", condition: .when(platforms: [.iOS])),
                .target(name: "OfstdXCFramework", condition: .when(platforms: [.iOS])),
                .target(name: "Openjp2XCFramework", condition: .when(platforms: [.iOS]))
            ],
            // NOTE (iOS port): cSettings/cxxSettings below are left
            // unconditional (pointing at the macOS install under
            // libs/dcmtk|openjpeg/include) even for the iOS build -- DCMTK/
            // OpenJPEG headers are architecture-independent C/C++ text, so
            // the exact same header content works for compiling either
            // platform's sources, and scripts/setup_native_deps_ios.sh
            // already requires scripts/setup_native_deps.sh (macOS) to have
            // been run first (it reuses that build's generated arith.h), so
            // this path is guaranteed to exist by the time an iOS build is
            // attempted. This deliberately avoids reintroducing the
            // `.when(platforms: [.macOS])`-on-headerSearchPath bug noted
            // below (that failure was specific to conditioning a
            // headerSearchPath -- unrelated to leaving one unconditional).
            cSettings: [
                .headerSearchPath("../../libs/dcmtk/include"),
                .headerSearchPath("../../libs/openjpeg/include/openjpeg-2.5")
            ],
            cxxSettings: [
                .headerSearchPath("../../libs/dcmtk/include"),
                .headerSearchPath("../../libs/openjpeg/include/openjpeg-2.5"),
                .define("DCMTK_BUILD_IN_PROGRESS")
            ],
            // NOTE (iOS port): an earlier version of this file wrapped every
            // setting in this target in `.when(platforms: [.macOS])`,
            // intending to prepare for iOS-conditioned settings being added
            // later, but that broke the macOS Xcode build (a
            // `.headerSearchPath` gated this way stopped resolving even
            // though the target file it pointed at genuinely existed on
            // disk) and was reverted -- see the cSettings/cxxSettings NOTE
            // above for why that's not being repeated here. linkerSettings
            // below ARE now conditioned per-platform, since that's a
            // different setting type than what broke before, and is
            // unavoidable here: the macOS-only -L path/library names below
            // can't be left unconditional without breaking an iOS link
            // (there is no macOS-built libdcmimage.a etc. reachable for an
            // iOS target, nor should there be -- iOS links the
            // XCFramework binaryTarget dependencies above instead).
            linkerSettings: [
                .unsafeFlags(["-Llibs/dcmtk/lib", "-Llibs/openjpeg/lib"], .when(platforms: [.macOS])),
                .linkedLibrary("dcmimage", .when(platforms: [.macOS])),
                .linkedLibrary("dcmimgle", .when(platforms: [.macOS])),
                .linkedLibrary("dcmdata", .when(platforms: [.macOS])),
                .linkedLibrary("oflog", .when(platforms: [.macOS])),
                .linkedLibrary("ofstd", .when(platforms: [.macOS])),
                .linkedLibrary("dcmjpeg", .when(platforms: [.macOS])),
                .linkedLibrary("dcmjpls", .when(platforms: [.macOS])),
                .linkedLibrary("dcmtkcharls", .when(platforms: [.macOS])),
                .linkedLibrary("ijg8", .when(platforms: [.macOS])),
                .linkedLibrary("ijg12", .when(platforms: [.macOS])),
                .linkedLibrary("ijg16", .when(platforms: [.macOS])),
                .linkedLibrary("oficonv", .when(platforms: [.macOS])),
                .linkedLibrary("openjp2", .when(platforms: [.macOS])),
                // z (zlib) is a system library present in both the macOS and
                // iOS SDKs -- needed on both, so left unconditional.
                .linkedLibrary("z")
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
