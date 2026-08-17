# Building the iOS app target

This package was restructured (see `Package.swift`) to split the app into two
pieces:

- **`OpenDicomViewerCore`** -- a SwiftPM library target/product containing
  every view, model, and rendering type, plus the shared SwiftUI `App` scene
  (`OpenDicomViewerCoreApp`, in `Sources/OpenDicomViewer/OpenDicomViewerCoreApp.swift`).
- **`OpenDicomViewer`** -- a thin macOS-only executable target
  (`Sources/OpenDicomViewerMacApp/main.swift`) that just calls
  `OpenDicomViewerCoreApp.main()`. This keeps `swift build` / `scripts/package_app.sh`
  working exactly as before.

A SwiftPM `.executableTarget` is a macOS/Linux/Windows-only concept -- it
cannot produce an installable iOS app bundle (no Info.plist, no code signing,
no provisioning profile, no app icon catalog). iOS apps need a real **Xcode
App target**. This repo does not include an `.xcodeproj`/`.xcworkspace` yet
(unlike SARSTripLog, which uses XcodeGen), so creating and wiring up the iOS
target needs to happen once, by hand, in Xcode on a Mac. These are the exact
steps:

## 0. Add iOS back to Package.swift's platforms list

`Package.swift`'s `platforms:` is currently `[.macOS(.v14)]` only -- iOS was
deliberately pulled back out after it turned out to have an immediate side
effect on the macOS build (see the NOTE comment right above `platforms:` in
`Package.swift`): merely declaring iOS support made Xcode offer a "My Mac
(Mac Catalyst)" destination for the `OpenDicomViewer` scheme, and
`DCMTKHelper.mm`'s `NSImage(cgImage:size:)` calls are hard compile errors
under Catalyst ("not available on macCatalyst") -- Catalyst was never wanted
here, it just became reachable once iOS was declared with nothing yet
consuming it.

Before starting step 1, add `.iOS(.v17)` back to the `platforms:` array. Do
this in the *same* sitting as creating the Xcode target below (not before),
so if it reintroduces the Catalyst-destination side effect (or anything
similar), it's diagnosed and fixed right away instead of quietly breaking the
macOS build again later. If it recurs: check the scheme/destination picker at
the top of the Xcode window for the `OpenDicomViewer` (macOS) scheme -- it
should only ever say "My Mac", never "My Mac (Mac Catalyst)" or "My Mac
(Designed for iPad)".

## 1. Create the Xcode project + iOS target

1. In Xcode: **File -> New -> Project -> iOS -> App**.
2. Product Name: `OpenDicomViewer` (or `OpenDicomViewerApp` to avoid clashing
   with the SwiftPM target name -- either is fine, they're in different
   namespaces).
3. Interface: **SwiftUI**. Language: **Swift**. Uncheck "Include Tests" (the
   package already has its own test target) unless you want native iOS UI
   tests later.
4. Save the project inside this repo root (e.g. as `OpenDicomViewerApp.xcodeproj`),
   sibling to `Package.swift`.
5. Delete the placeholder `ContentView.swift` and `<ProjectName>App.swift`
   Xcode generated -- they're not needed, `OpenDicomViewerCoreApp` replaces
   both.

## 2. Add this package as a local dependency

1. With the new project open: **File -> Add Package Dependencies... -> Add
   Local...**, then select this repo's root folder (the one containing
   `Package.swift`).
2. When prompted which products to link, select **`OpenDicomViewerCore`**
   only -- not the `OpenDicomViewer` executable product (Xcode will likely
   hide/disable that one anyway since executable products aren't linkable).
3. Add it to your new iOS app target under **General -> Frameworks, Libraries,
   and Embedded Content**, or under **Package Dependencies** on the target's
   build phase, if Xcode didn't do this automatically.

## 3. Write the iOS entry point

Add one new Swift file to the Xcode target (not to the SwiftPM package) --
e.g. `OpenDicomViewerAppEntry.swift`:

```swift
import SwiftUI
import OpenDicomViewerCore

@main
struct OpenDicomViewerAppEntry: App {
    var body: some Scene {
        OpenDicomViewerCoreApp().body
    }
}
```

This mirrors `Sources/OpenDicomViewerMacApp/main.swift`'s role for macOS: it's
the only platform-specific glue needed to boot the shared `OpenDicomViewerCoreApp`
scene from a real iOS app bundle.

## 4. Known blockers past this point

Wiring up the target gets the project *structurally* ready, but it will not
build successfully yet, because of work still in progress elsewhere in this
port:

- **DCMTK/OpenJPEG are not built for iOS yet.** `Package.swift`'s
  `DCMTKWrapper` target currently only points at the macOS static libraries in
  `libs/dcmtk` and `libs/openjpeg`, unconditionally (an earlier revision
  conditioned these settings on `.macOS` via `.when(platforms:)` to prepare
  for iOS, but that broke the macOS build -- a header search path gated this
  way stopped resolving even though the file it pointed at genuinely existed
  on disk -- so it was reverted; see the NOTE in `Package.swift` itself).
  Building for an iOS/iOS Simulator destination will fail at the **compile**
  step, not just linking -- `DCMTKHelper.mm` unconditionally `#include`s DCMTK
  headers, and there's no iOS header search path configured at all. This
  needs DCMTK + OpenJPEG cross-compiled for `arm64` (device) and
  `arm64`/`x86_64` (simulator) -- tracked as its own task. Once built, prefer
  packaging them as an **XCFramework** and adding a `.binaryTarget` rather
  than trying to extend the current `unsafeFlags`-based `-L` linking to iOS,
  since SwiftPM/Xcode reject `unsafeFlags` in a package that's consumed as a
  dependency the way this target now is.
- **`DCMTKHelper.convertDICOM(toNSImage:)` and `-renderImageWithWidth:...`**
  (the Objective-C++ bridge in `Sources/DCMTKWrapper/DCMTKHelper.mm`/`.h`) are
  hardcoded to return `NSImage`, i.e. they only compile against AppKit. This
  needs to change to return a `CGImageRef` (or be duplicated per-platform)
  before `DCMTKWrapper` itself can even compile for iOS -- independent of
  having iOS-built `.a`/XCFramework libs to link against.
- **`DICOMModel.openFolder()` (NSOpenPanel) and the global Shift-key `NSEvent`
  monitor** are gated behind `#if os(macOS)` with no iOS implementation yet.
  iOS file picking should use SwiftUI's `.fileImporter` (or
  `UIDocumentPickerViewController`) calling `DICOMModel.load(url:)` directly
  from the view layer instead.
- **`ContentView.swift`, `MultiPanelContainer.swift`, `WindowAccessor.swift`**
  still contain the original macOS mouse/keyboard-driven interaction code
  (`NSView` subclasses for drag-based window/level, pan, slice-scrolling,
  `NSCursor`, `NSEvent`-based keyboard shortcuts). None of this has an iOS
  touch equivalent yet; a parallel SwiftUI-gesture-based iOS interaction layer
  is planned as a separate task, alongside (not replacing) this macOS code.

None of the above blocks creating and committing the Xcode project itself --
they'll surface as build errors when you actually try to compile for an iOS
destination, at which point they can be tackled one at a time with real
compiler feedback (something this sandbox cannot provide, since it has no
Xcode/iOS SDK).

## 5. Cross-compiling DCMTK + OpenJPEG for iOS

`scripts/setup_native_deps_ios.sh` is a starting point for the first blocker
above. It mirrors `scripts/setup_native_deps.sh` (the existing, known-good
macOS build script) across three additional CMake platform slices --
`OS64` (iOS device, arm64), `SIMULATORARM64`, and `SIMULATOR64` -- using the
community-maintained [ios-cmake](https://github.com/leetal/ios-cmake)
toolchain file (downloaded automatically, pinned to `4.5.0`) rather than a
hand-rolled iOS `CMAKE_TOOLCHAIN_FILE`, since that project already solves the
hard part: CMake's `try_run()`-based configure checks (endianness, type
sizes, etc.) can't execute an iOS binary on the macOS build host, and getting
that wrong tends to fail silently or hang rather than producing a clear error.

The two simulator slices are `lipo`'d together into one universal simulator
library per DCMTK/OpenJPEG static library, then each library is packaged as
an XCFramework (`libs/xcframeworks/<name>.xcframework`, device + simulator
slices) via `xcodebuild -create-xcframework`.

**This script has not been run.** I wrote it without a Mac/Xcode/iOS SDK
available to actually execute or debug it, so treat it as a first draft to
iterate on with real build output, not a known-working recipe. Specific risk
areas to expect trouble in, roughly in the order they're likely to bite:

1. **DCMTK's own CMake config may not fully support iOS cross-compilation
   out of the box**, even with ios-cmake handling the toolchain mechanics.
   DCMTK 3.6.8 predates widespread iOS-target CMake support; some of its
   `configure`-style checks may need additional cache variables pre-seeded
   (ios-cmake's README documents the pattern for this) or, in the worst case,
   small source patches. Existing "DCMTK for iOS" community projects (search
   GitHub/CocoaPods) that have already solved this are worth checking before
   patching from scratch.
2. **`dcmnet`'s use of POSIX networking APIs** should mostly work on iOS
   (it's POSIX sockets, which iOS supports), but hasn't been checked
   line-by-line for anything Darwin/macOS-specific that iOS's sandboxed
   networking stack might reject or behave differently for -- worth a close
   look before wiring up the PACS networking task on top of it.
3. **The lipo/XCFramework packaging step assumes both simulator slices build
   the exact same set of `.a` files with matching names** -- if DCMTK's CMake
   enables/disables optional libraries differently per-arch (it shouldn't,
   but hasn't been observed), `lipo_all`'s mismatch warning will say so.

Once real `.xcframework` outputs exist, `Package.swift`'s `DCMTKWrapper`
target needs a follow-up change: replace its `unsafeFlags`-based `-L` linker
flags (macOS-only today) with `.binaryTarget` entries for the iOS platform,
since `unsafeFlags` make a package unusable as a dependency the way the iOS
Xcode target now depends on this one -- this wasn't done yet since it should
be wired up against XCFrameworks that actually exist and have been confirmed
to contain the expected architecture slices, not speculatively.
