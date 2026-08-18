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

- ~~DCMTK/OpenJPEG are not built for iOS yet.~~ **Done.** `scripts/setup_native_deps_ios.sh`
  cross-compiles DCMTK 3.6.8 + OpenJPEG 2.5.0 for iOS device (`arm64`) and iOS
  Simulator (`arm64` only -- the `x86_64` Simulator slice was dropped; see the
  NOTE at the top of that script for why), packages each library as an
  XCFramework under `libs/xcframeworks/`, and `Package.swift`'s `DCMTKWrapper`
  target now depends on those XCFrameworks via `.binaryTarget` (iOS-only,
  gated with `.when(platforms: [.iOS])`) alongside its existing macOS
  `unsafeFlags`-based `-L`/`-l` linking (now gated to `.macOS` instead of
  left unconditional). Getting the cross-compile itself working took several
  rounds of real build-output-driven fixes -- see the NOTE comments through
  `scripts/setup_native_deps_ios.sh` for the full list (a DCMTK/iOS Darwin
  feature-test-macro gap, several compiler-quirk probes with no tolerance for
  their own expected "no" answer, a fundamentally un-cross-compilable runtime
  probe worked around by reusing the macOS build's already-generated
  `arith.h`, and several link-time false positives for libraries that don't
  exist on Apple platforms at all) if a similar issue resurfaces.
  This alone does **not** make `DCMTKWrapper` compile for iOS yet, though --
  see the next bullet.
- ~~`DCMTKHelper.convertDICOM(toNSImage:)` and `-renderImageWithWidth:...`
  are hardcoded to return `NSImage`.~~ **Done.** The Objective-C++ bridge
  (`Sources/DCMTKWrapper/DCMTKHelper.mm`/`.h`) no longer imports AppKit at
  all or returns `NSImage` from anything -- `DCMTKHelper.convertDICOMToDisplayPixels(_:width:height:samples:)`
  and `DCMTKImageObject.renderPixelData(ww:wc:width:height:samples:)` now
  return the decoded/rendered image as raw 8-bit pixel bytes (`NSData`, gray
  or interleaved RGB per `samples`) plus its dimensions instead, matching the
  shape `getRawPixelData:`/`decodeJPEG2000DICOM:` already used (they never
  touched AppKit). `Sources/OpenDicomViewer/PlatformCompat.swift`'s new
  `PlatformImageFactory.make(dcmtkPixelData:width:height:samples:)` and two
  new private helpers in `DICOMModel.swift`
  (`decodeDICOMToPlatformImage(path:)`, `renderPlatformImage(from:ww:wc:)`)
  reconstruct the `CGImage`/`PlatformImage` from those bytes on the Swift
  side instead, which works identically on macOS and iOS -- see the NOTE
  comments in `DCMTKHelper.h` and `PlatformCompat.swift` for the full
  reasoning. `NS_SWIFT_NAME` pins the exact Swift name for both renamed
  Objective-C methods rather than relying on the Clang importer's
  preposition-splitting heuristic.
  **Verified with a real `swift build` on macOS** (the sandbox that made this
  change has no Swift toolchain of its own). That build caught one knock-on
  issue worth knowing about if a similar AppKit-removal happens again:
  `MPREngine.swift` used `CGContext`/`CGColorSpaceCreateDeviceGray`/
  `CGImageAlphaInfo` without ever explicitly importing `CoreGraphics` -- it
  had been getting those symbols for free because `DCMTKHelper.h` used to
  `#import <AppKit/AppKit.h>`, and Swift's ClangImporter exposes a Clang
  module's whole transitive header-include graph to any Swift file that
  imports it. Removing AppKit from `DCMTKHelper.h` closed that accidental
  side channel and surfaced the missing import as real compile errors;
  fixed by just adding `import CoreGraphics` to `MPREngine.swift`. Every
  other Swift file in the project was audited for the same risk (any raw
  CoreGraphics C-API use without an explicit `CoreGraphics`/`AppKit`/`UIKit`
  import) -- none found; the rest only use basic geometry types
  (`CGPoint`/`CGRect`/`CGSize`/`CGFloat`), which come bundled with plain
  `import Foundation` on Apple platforms via `NSGeometry.h`, independent of
  AppKit.
- ~~`DICOMModel.openFolder()` (NSOpenPanel) and the global Shift-key `NSEvent`
  monitor have no iOS implementation.~~ **Done** (openFolder), **acceptable
  as-is** (Shift monitor). `SidebarView` (ContentView.swift) now drives a
  SwiftUI `.fileImporter` on iOS instead, calling `DICOMModel.load(url:)`
  directly with the picked URL -- see `SidebarView.openFile()`/
  `.fileImporter(...)`. This surfaced a real, previously-latent bug in
  `load(url:)`: it released the security-scoped resource via `defer` at the
  end of its *synchronous* body, but the actual directory scan/file load runs
  *asynchronously* on `DispatchQueue.main.async` just below that -- so the
  scope was being released before the async work it was protecting ever ran.
  Invisible on a non-sandboxed macOS build (`startAccessingSecurityScopedResource()`
  always returns `false` there, making the deferred release a no-op regardless
  of timing), but a real bug for iOS, where every app is sandboxed and a
  `.fileImporter`-picked URL outside the app's container genuinely needs its
  scope held open for as long as files are read from it. Fixed by holding the
  scope open for the dataset's lifetime (released when the *next* `load(url:)`
  call acquires a different URL, or at `deinit`) instead of trying to
  precisely bracket the async scan -- see the NOTE comments on
  `DICOMModel.load(url:)` and the new `securityScopedURL` property. The
  Shift-key monitor itself has no touch equivalent (there's no modifier key),
  but its one consumer -- Shift+click group-panel-selection for synchronized
  scrolling -- now has a touch substitute (long-press, see the next bullet),
  so leaving `isShiftHeld` permanently `false` on iOS (nothing sets it there)
  is fine as-is rather than something to build a replacement affordance for.
- ~~`ContentView.swift`, `MultiPanelContainer.swift`, `WindowAccessor.swift`
  still contain the original macOS mouse/keyboard-driven interaction code...
  None of this has an iOS touch equivalent yet.~~ **Mostly done.** The core
  per-panel interaction surface (`PanelInteractiveDICOMView`/
  `PanelDICOMInteractView` in `MultiPanelContainer.swift`, by far the largest
  piece -- pan/zoom/window-level/ROI/ruler/angle/eraser/slice-navigation/cine)
  now has a full iOS touch counterpart in the new
  `Sources/OpenDicomViewer/PanelTouchInteractView.swift`, using the *same*
  symbol names (`PanelInteractiveDICOMView`, nested `PanelDICOMInteractView`)
  so `PanelView` and DICOMModel.swift's cine-playback code needed zero call-site
  changes -- whichever platform's version of the symbol exists is the only one
  visible to that build. `PanelScrollerInteractionView` (the per-panel slice
  scrub track) got the same treatment. See `PanelTouchInteractView.swift`'s
  extensive header NOTE for the full mouse-to-touch interaction mapping
  (1-finger touch = tool-dependent, mirrors mouseDown/Dragged/Up; 2-finger pan
  = window/level, replacing right-click-drag; pinch = zoom; long-press =
  toggle group-selection, replacing Shift+click; vertical drag while the
  `.select` tool is active = slice navigation, reusing the one tool mouseDragged
  did nothing for) and its explicit list of what's *not* ported yet (HU-readout
  hover-follow, drag-and-drop of a sidebar series row onto a panel -- both
  tracked as explicit follow-ups, not silently dropped). `WindowAccessor.swift`
  (NSWindow titlebar/traffic-light customization -- a macOS window-chrome
  concept with no iOS equivalent at all) and the entire legacy, macOS-only,
  already-unused-in-the-live-UI `DetailView`/`InteractiveDICOMView`/
  `ScrollerInteractionView` block in `ContentView.swift` are now gated behind
  `#if os(macOS)` instead (confirmed dead code via a zero-call-sites check
  before gating, so nothing was lost on either platform). `ToolPalette`
  (MultiPanelContainer.swift) gained an iOS-only extra button row for
  reset/invert/flip/rotate/fit-to-window, which previously only had keyboard
  shortcuts and no on-screen affordance at all on any platform.
  `UpdateChecker.swift` (`NSWorkspace.shared.open`) and a stray
  `Image(nsImage:)` call in `MultiPanelContainer.swift`/`ContentView.swift`
  (SwiftUI's `Image(nsImage:)`/`Image(uiImage:)` are separate,
  platform-specific initializers even though the underlying `PlatformImage`
  they wrap is unified) also needed platform-conditional fixes to compile for
  iOS at all, found via an exhaustive project-wide sweep for any unconditional
  `NS*`-prefixed symbol -- see that audit's results in this file's git history
  if a similar gap needs re-checking later.

**IMPORTANT CAVEAT:** none of the touch-layer code above has been compiled,
by anyone, on anything, yet -- and unlike the DCMTKHelper/MPREngine fixes
earlier in this doc, a macOS `swift build` *cannot* catch mistakes in it: with
`.iOS(.v17)` not yet back in `Package.swift`'s `platforms:` (step 0 below),
the Swift compiler never even parses `#if os(iOS)` code in a macOS build, so
`swift build` succeeding proves nothing about whether `PanelTouchInteractView.swift`
or any of the other `#if os(iOS)` branches above actually compile. This will
only get real compiler feedback once step 0 below is done and an actual Xcode
iOS App target (steps 1-3) builds for a real iOS destination. Expect a
debugging pass at that point, the same way the DCMTK cross-compile itself took
several rounds against real build output -- this was written as carefully as
possible against the exact macOS implementation it mirrors (including reading
the full ~1000-line `PanelDICOMInteractView` source, not just a summary of
it), but "carefully written, never compiled" is a fundamentally different risk
profile from changes a macOS build could actually verify.

Remaining known gaps, not blockers for a first buildable iOS target but worth
tracking:
- HU-readout live-follow (no touch "hover"), and ruler/angle preview lines
  between the first and second tap, are not ported -- see the header NOTE in
  `PanelTouchInteractView.swift`.
- Drag-and-drop of a sidebar series row onto a panel (`NSItemProvider`-based
  on macOS) has no iOS destination-side handling -- needs its own UX design
  pass (e.g. tap-to-assign for compact-width iPhone) rather than a mechanical
  port; `model.assignSeriesToPanel`/`model.load(url:)` are ready for it
  whenever that lands.
- `UpdateChecker.swift`'s GitHub-releases-`.dmg` update checker is
  macOS-distribution-specific by design; it now compiles for iOS but doesn't
  make product sense there as-is (an iOS build would use App Store/TestFlight
  updates instead) -- whether/how to adapt or disable it on iOS is a product
  decision, not a build fix.

None of the above blocks creating and committing the Xcode project itself --
remaining issues will surface as build errors when you actually try to
compile for an iOS destination, at which point they can be tackled one at a
time with real compiler feedback (something this sandbox cannot provide,
since it has no Xcode/iOS SDK).

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

The simulator slice is packaged as an XCFramework alongside the device slice
(`libs/xcframeworks/<name>.xcframework`, device + simulator slices) via
`xcodebuild -create-xcframework`. (Originally planned as two simulator
slices, `arm64` + `x86_64`, `lipo`'d together into one universal simulator
library -- the `x86_64` slice was dropped; see the NOTE at the top of the
script for why.)

**Status: done, build-tested, and producing working XCFrameworks** --
`libs/xcframeworks/` now contains every library `Package.swift`'s
`DCMTKWrapper` target needs (`dcmdata`, `dcmimage`, `dcmimgle`, `dcmjpeg`,
`dcmjpls`, `dcmtkcharls`, `ijg8`, `ijg12`, `ijg16`, `oficonv`, `oflog`,
`ofstd`, `openjp2`), plus `dcmnet`/`dcmqrdb`/`dcmtls` for the future PACS
networking task. This took several rounds of real-build-output-driven fixes
beyond what the risk areas below anticipated -- see the NOTE comments
throughout `scripts/setup_native_deps_ios.sh` for the full, specific list
(each `-D<VAR>=<value>` cache seed and source patch documents exactly what
it fixes and why) if a similar issue resurfaces, e.g. when adding `dcmnet`
to the actual link list for the PACS networking task.

Original anticipated risk areas, kept for reference (all of #1 and #3 did in
fact bite, in the specific forms documented in the script; #2 hasn't been
investigated yet since `dcmnet` isn't linked by anything yet):

1. **DCMTK's own CMake config didn't fully support iOS cross-compilation out
   of the box**, even with ios-cmake handling the toolchain mechanics. This
   needed several cache variables pre-seeded (DCMTK's own configure checks
   have no way to determine some answers when cross-compiling, and in one
   case -- `HAVE_DECLSPEC_DEPRECATED_MSG` and similar compiler-quirk probes
   -- no tolerance for compile failure being their own normal, expected
   answer) plus one direct source patch (`CMake/dcmtkPrepare.cmake`'s
   Darwin/iOS flag-detection branch was missing `-D_DARWIN_C_SOURCE`, which
   the sibling macOS branch already had).
2. **`dcmnet`'s use of POSIX networking APIs** should mostly work on iOS
   (it's POSIX sockets, which iOS supports), but hasn't been checked
   line-by-line for anything Darwin/macOS-specific that iOS's sandboxed
   networking stack might reject or behave differently for -- worth a close
   look before wiring up the PACS networking task on top of it.
3. **The lipo/XCFramework packaging step assumed both simulator slices would
   build the exact same set of `.a` files with matching names** -- moot now
   that the `x86_64` simulator slice has been dropped (see above), but if it
   were ever added back, this is still a real risk worth checking for.

`Package.swift`'s `DCMTKWrapper` target now depends on these XCFrameworks via
`.binaryTarget` entries, gated to iOS only (`.when(platforms: [.iOS])`),
alongside its existing macOS `unsafeFlags`-based `-L`/`-l` linking (now gated
to `.macOS` instead of left unconditional) -- see the NOTE comments in
`Package.swift` itself for the full reasoning. This wiring is deliberately
inert until iOS is actually added back to `platforms:` (step 0 above) and a
real Xcode iOS App target exists to consume it -- and even then,
`DCMTKWrapper` still won't compile for iOS until the AppKit-only code in
`DCMTKHelper.mm` (see the "Known blockers" list above) is fixed, independent
of these XCFrameworks now existing and being correctly wired in.
