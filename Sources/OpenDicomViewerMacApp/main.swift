// main.swift
// OpenDicomViewer (macOS executable shim)
//
// This target is intentionally tiny: SwiftPM's `.executableTarget` is what
// `swift build` / scripts/package_app.sh use to produce the macOS binary and
// .app bundle, but a bare executable target cannot produce an installable iOS
// app -- that needs a real Xcode "App" target instead (see docs/iOS-Build.md).
// So all of the actual app UI/logic lives in the shared OpenDicomViewerCore
// library target, and this file's only job is to forward into it.
//
// A plain top-level `main.swift` (rather than an `@main`-attributed struct) is
// used here because `OpenDicomViewerCoreApp` -- the type that actually
// conforms to `App` -- lives in a different module (OpenDicomViewerCore) and
// SwiftUI's `App.main()` is a normal static method inherited from the `App`
// protocol's default implementation, so it can simply be called directly.
// Licensed under the MIT License. See LICENSE for details.

import OpenDicomViewerCore

OpenDicomViewerCoreApp.main()
