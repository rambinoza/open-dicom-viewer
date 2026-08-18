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
`ofstd`, `openjp2`), plus `dcmnet` (now actually linked -- see section 6
below for the PACS networking task built on top of it) and `dcmqrdb`/
`dcmtls` (cross-compiled but deliberately left unused -- see section 6 for
why). This took several rounds of real-build-output-driven fixes beyond what
the risk areas below anticipated -- see the NOTE comments throughout
`scripts/setup_native_deps_ios.sh` for the full, specific list (each
`-D<VAR>=<value>` cache seed and source patch documents exactly what it
fixes and why) if a similar issue resurfaces.

Original anticipated risk areas, kept for reference (all of #1 and #3 did in
fact bite, in the specific forms documented in the script; #2 remains
unconfirmed -- section 6's PACS networking code compiled cleanly against
`dcmnet`'s headers, which says nothing about whatever Darwin/POSIX socket
code lives inside the already-built `libdcmnet.a` itself. That can only
really be confirmed by a real C-ECHO succeeding against a real PACS from a
real iOS device/Simulator -- flagged as the first thing to try once an Xcode
iOS App target exists, not assumed fine):

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

## 6. PACS networking (C-ECHO / C-FIND / C-GET / C-STORE)

**Status: implemented, partially verified -- see the verification breakdown
below, which is more granular than for any other piece of this port so far.**

`dcmnet` is now wired into `Package.swift` (`DcmnetXCFramework` binaryTarget
for iOS, `.linkedLibrary("dcmnet", ...)` for macOS) alongside a new
three-file implementation:

- **`Sources/DCMTKWrapper/include/pacs_core.hpp` +
  `Sources/DCMTKWrapper/pacs_core.cpp`** -- the actual DCMTK `dcmnet` API
  usage (a `DcmSCU` subclass plus free functions for echo/find/retrieve/
  store), deliberately written as **pure C++ with zero Foundation/Objective-C
  dependency**, specifically so it could be checked with a real compiler.
  This sandbox turned out to already have a full macOS arm64 DCMTK 3.6.8
  build on disk (headers *and* `.a` libraries, at `libs/dcmtk/` -- built by
  an earlier `scripts/setup_native_deps.sh` run, `.gitignore`'d like the
  rest of `libs/`) -- Linux can't *link* a macOS Mach-O binary, but
  `clang++ -std=c++17 -fsyntax-only -Wall -Wextra` against those real headers
  doesn't need to link, and does fully type-check every DCMTK class, method,
  enum, and constant name this file uses against their real declarations.
  That check passed with zero errors or warnings. This is a meaningfully
  stronger verification bar than anything else added in this port (including
  the touch-interaction layer and the file picker) -- but it still only
  proves *API usage matches real signatures*, not runtime correctness against
  an actual PACS server, which no amount of static checking can substitute
  for. See `pacs_core.hpp`'s header comment for the full design writeup,
  including two decisions worth knowing about before testing against a real
  PACS:
  - **C-GET instead of C-MOVE for retrieval.** C-MOVE requires the client to
    run its own permanently-listening Storage SCP for the PACS to connect
    back to (bad fit for a mobile/NAT'd/backgrounded app); C-GET streams
    retrieved instances back as C-STORE sub-operations on the *same*
    already-open association, needing no listener at all. The tradeoff: a
    small minority of older/stricter PACS only implement C-MOVE. Not
    implemented as a fallback here -- a known, explicit follow-up.
  - **A curated storage SOP class list, not DCMTK's full
    `dcmAllStorageSOPClassUIDs`**, is proposed as presentation contexts for
    C-GET/C-STORE (`kStorageSOPClasses` in `pacs_core.cpp`: CT, MR, enhanced
    CT/MR, CR, DX, US, secondary capture, XA, NM, PET, RT image/dose/struct/
    plan). A DICOM association caps presentation contexts at 128
    (1-byte, odd-only context ID), and this sandbox had no way to confirm
    whether DCMTK's association negotiation silently truncates, errors, or
    does something else if asked to propose more than that -- rather than
    guess, the list covers the modalities this viewer's local-file decode
    path already supports and stays comfortably under the limit. An
    unusual modality's SOP class not in this list will fail to retrieve
    with an explicit "no presentation context" error on that instance, not
    silently -- extend the list if that happens against a real PACS.
  - Also worth knowing: `DCMTK_WITH_OPENSSL=OFF` (a deliberate choice made
    earlier in this port to avoid an extra cross-compiled dependency) means
    `dcmtls` has no real TLS backing even though it's cross-compiled --
    encrypted DICOM (TLS) is **not supported**, and isn't wired into
    `Package.swift` at all (only `dcmnet` is linked; `dcmqrdb`/`dcmtls`
    XCFrameworks exist on disk, unused). Plain, unencrypted DICOM networking
    only, same as most on-premises hospital PACS deployments today, but
    worth flagging for anyone pointing this at a PACS that requires TLS.
- **`Sources/DCMTKWrapper/include/PACSHelper.h` +
  `Sources/DCMTKWrapper/PACSHelper.mm`** -- the Objective-C++ bridge exposing
  `pacs_core`'s functionality to Swift as `PACSClient`/`PACSStudyResult`,
  following the same ivar/init conventions `DCMTKHelper.mm` already
  established. **Not compiler-verified** (no Foundation/ObjC runtime in the
  sandbox to check it against) -- ordinary NSString/NSArray/block bridging
  code, but genuinely unverified, unlike `pacs_core.cpp`. Also factored a
  previously-`static`, `DCMTKHelper.mm`-private `ensureDCMTKInitialized()`
  (DCMDICTPATH setup, required before any DCMTK call from any file) out to
  a new shared internal header (`DCMTKSharedInit.h`) so `PACSHelper.mm`
  could call the exact same one-time init rather than duplicating it.
- **`Sources/OpenDicomViewer/PACSService.swift`** (async/await wrapper +
  `PACSNode`/`PACSStudy` Swift value types + `PACSSettingsStore` for
  persisting the last-used node to `UserDefaults`) and
  **`Sources/OpenDicomViewer/PACSBrowserView.swift`** (the SwiftUI query/
  retrieve sheet: server settings, C-ECHO test, STUDY-level C-FIND search,
  results list, per-study C-GET retrieve with progress, then
  `DICOMModel.load(url:)` on the retrieved folder to open it through the
  exact same path local files already use). **Not compiler-verified** --
  same caveat as every other `.swift` file in this whole port; no Swift
  toolchain has ever been available in the sandbox that wrote any of it.
  `PACSBrowserView` is plain SwiftUI with no AppKit/UIKit dependency at all,
  so unlike most of this port's view-layer work it needed no `#if os(...)`
  gating for its own sake (a few `#if os(iOS)` blocks exist only for
  iOS-only *keyboard type* modifiers, all in the already-proven-safe
  "continue an existing chain, no `#else`" shape -- see the aspectRatio/View
  compile-error writeup elsewhere in this project's history for the *unsafe*
  shape that pattern must avoid).
- **`Sources/OpenDicomViewer/ContentView.swift`** -- `SidebarView` gained a
  toolbar button (network icon) opening `PACSBrowserView` as a sheet,
  unconditionally on both platforms.

**Verification summary, most to least verified:**
1. `pacs_core.cpp`'s DCMTK API usage -- real compiler, real headers,
   `-fsyntax-only -Wall -Wextra`, clean. Proves API-shape correctness, not
   runtime correctness.
2. Everything else (the ObjC++ bridge, all the new Swift code, the
   `Package.swift` wiring) -- written carefully, matching established
   patterns elsewhere in this codebase, but genuinely unverified by any
   compiler. The very first `swift build` after this lands will be the
   first time *any* of it has been parsed by a real Swift compiler, and (per
   the `.iOS(.v17)`/`platforms:` situation described in "Known blockers"
   above) even that only checks the macOS side -- the iOS-specific paths
   still need step 0 done and a real Xcode iOS App target built to get real
   feedback.
3. Runtime behavior against an actual PACS -- **completely unverified**, and
   can't be, from this sandbox. No DICOM network exists to test against.
   Before relying on this for real studies, test C-ECHO first (cheapest,
   fastest way to confirm host/port/AE title configuration and basic
   connectivity), then a small C-FIND, then a C-GET retrieve of one small
   study, against a real or test PACS (many vendors' PACS/VNA products, and
   the open-source [Orthanc](https://www.orthanc-server.com/) server, are
   reasonable options for a test target) before trusting it against
   production data.

Not implemented (explicit follow-ups, not silently missing):
- C-MOVE (see the C-GET-vs-C-MOVE design note above) as a fallback for PACS
  that don't support C-GET.
- TLS/encrypted DICOM (`DCMTK_WITH_OPENSSL=OFF`; see above).
- Multi-node PACS "address book" -- `PACSSettingsStore` persists exactly one
  node today.
- Query levels other than STUDY (no PATIENT/SERIES/IMAGE-level C-FIND, no
  drill-down from a study into its series before retrieving).

## 7. Study library: browse / delete / import / send / share

**Status: implemented, not compiler-verified -- same caveat as every other
`.swift` file in this port; no Swift toolchain has ever been available in
this sandbox.**

Adds a local database of studies plus UI to browse, delete, import from a
folder or ZIP archive, and send or share a study/series/image/screen-save.
Six files, two new UI surfaces:

- **`Sources/OpenDicomViewer/StudyDatabase.swift`** -- a `StudyRecord`
  struct (patient/study summary fields + a Documents-*relative* `folderPath`,
  never an absolute path, since the sandbox container's absolute path isn't
  guaranteed stable across relaunches) and a `StudyDatabase` singleton
  wrapping Apple's system `libsqlite3` directly via `import SQLite3` (no
  third-party wrapper, no Core Data -- Core Data would need a hand-authored
  `.xcdatamodeld`, normally built with Xcode's visual editor and brittle to
  write blind). One table, `upsert`/`allStudies`/`delete`, all calls
  serialized onto a private `DispatchQueue` since this is read from both the
  main actor (`LibraryView`) and background import/PACS-retrieve code.
- **`Sources/OpenDicomViewer/StudyImportService.swift`** -- the import
  pipeline. **Design decision worth knowing:** importing a folder or ZIP
  always *copies*/*extracts* into this app's own
  `Documents/ImportedStudies/<uuid>/` first, and only registers that managed
  copy in the database -- never the original externally-picked location.
  An externally-picked URL (from `.fileImporter`, security-scoped) is only
  guaranteed valid for that one picker session, but a "browse your library
  any time" screen needs paths that stay valid indefinitely across app
  relaunches. This roughly doubles disk usage versus the source while it
  still exists elsewhere -- an accepted tradeoff. The pre-existing
  `SidebarView` "Open" button is unaffected and still just views a folder in
  place without copying or registering it. ZIP extraction/creation uses the
  new `ZIPFoundation` SPM dependency (`.package(url:
  "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0")`, added to
  `Package.swift`'s `dependencies:` and to `OpenDicomViewerCore`'s target
  dependencies) -- its exact API (`FileManager.unzipItem`/`zipItem`
  signatures) was fetched and confirmed against the real published
  documentation before use, not recalled from memory. Also reads
  PatientName/StudyDate/StudyDescription/AccessionNumber/Modality from the
  first parsable file in an imported folder for the database summary row --
  no existing code in this codebase read those tags before now (the
  pre-existing `SimpleDicomParser` in `SimpleDICOM.swift` is the only
  tag-reading tool in the app; `DICOMModel`'s own private tag-reading only
  covers what it needs for series/geometry, not these patient/study fields).
  A folder containing more than one study's worth of files registers only
  the *first* study found as one database row (documented simplification,
  not a bug -- the folder still opens correctly and shows every study's
  images when opened directly).
- **`Sources/OpenDicomViewer/ShareMenuButton.swift`** -- `PrepareAndShareButton`,
  a small reusable two-phase component (tap to prepare a file in the
  background -- zip a folder, encode a PNG -- then a real SwiftUI `ShareLink`
  appears in its place to tap again). `ShareLink` has no imperative
  "trigger from code" API, so this two-tap shape is the straightforward way
  to combine it with any preparation step that takes real time, which every
  use in this app does. Also defines `PanelShareMenu`, a new toolbar menu
  (see below) for the viewer's active panel.
- **`Sources/OpenDicomViewer/LibraryView.swift`** -- the study-level browse
  sheet: list of studies (patient name, date, description, modality badges,
  local-vs-PACS-retrieved badge, instance count), tap to open, swipe or
  context menu to delete, toolbar buttons to import a folder or ZIP
  (`.fileImporter`, used unconditionally on *both* platforms here -- it's
  available on macOS 13+ too, not iOS-only; the existing iOS-only
  `.fileImporter` gating elsewhere in `ContentView.swift` was only because
  macOS already had `NSOpenPanel` for that specific case, not because
  `.fileImporter` itself needs it), and a context menu per study for "Send
  to PACS" (reuses `PACSService`/the one saved `PACSSettingsStore` node,
  same as PACS retrieve) and "Share / Email" (zips the whole study folder,
  hands it to `PrepareAndShareButton`).
- **`Sources/OpenDicomViewer/MultiPanelContainer.swift`** -- `ToolPalette`
  gained an unconditional (both platforms, no `#if os(...)`) `PanelShareMenu`
  button, since unlike the existing iOS-only reset/invert/flip/rotate row
  above it (added only because macOS already has keyboard shortcuts for
  those), there's no macOS keyboard equivalent for "send/share the currently
  displayed image or series." `PanelShareMenu` offers, for whatever's
  currently shown in the active panel: send current series / send current
  image to PACS; share current series (zipped) / share current image /
  share a "screen save". **Screen save is a plain PNG export of the panel's
  currently displayed pixel data only -- it does NOT burn in any annotation
  overlay** (measurements, text, etc. drawn on top in the viewer); that's a
  known, explicit follow-up, not silently missing. PNG encoding is via a new
  `PlatformImageFactory.pngData(from:)` in `PlatformCompat.swift`
  (`NSBitmapImageRep` on macOS, `UIImage.pngData()` on iOS).
- **`Sources/OpenDicomViewer/ContentView.swift`** -- `SidebarView` gained a
  toolbar button (`tray.full` icon) opening `LibraryView` as a sheet,
  unconditionally on both platforms, following the exact same pattern as the
  existing PACS button.
- **`Package.swift`** -- added the `ZIPFoundation` dependency (above) and
  `.linkedLibrary("sqlite3")` to `OpenDicomViewerCore`'s `linkerSettings`
  (that target previously had none). Both are system/SPM dependencies
  available on macOS and iOS alike, so neither needed platform conditioning.

**Two things worth flagging against the original request, which asked for
this "all in one":**
1. **Two UI surfaces, not one.** `LibraryView` (the database-backed browse
   screen) only operates at *study* granularity -- there's no per-series or
   per-image drill-down *within* the library itself, only whole-study
   rows. Series- and image-level send/share (plus the screen-save export)
   live instead in the *viewer's* toolbar, via the new `PanelShareMenu`,
   operating on whatever the active panel currently has open. Splitting it
   this way avoided inventing a second, parallel series/image browsing UI
   inside `LibraryView` when the viewer already has one.
2. **"Email" is implemented via the system share sheet (`ShareLink`), not a
   Mail-specific API.** `ShareLink` presents the OS share sheet, which
   includes Mail as one option among many (Messages, AirDrop, Save to
   Files, third-party apps, etc.) rather than composing a mail message
   directly via `MessageUI`/`MFMailComposeViewController`. This is more
   general (works even if the device has no Mail account configured, lets
   the user pick whatever app they actually want) but means there's no
   pre-filled subject/body/recipient the way a dedicated Mail compose sheet
   could offer -- a possible future enhancement if that's wanted
   specifically.

Not implemented (explicit follow-ups, not silently missing):
- Per-series/per-image rows inside `LibraryView` itself (see above).
- Annotation burn-in for screen-save PNG exports (see above).
- A picker for *which* PACS node to send to -- reuses the single saved
  `PACSSettingsStore` node, same limitation already noted in section 6.
- Dedicated Mail-compose integration (see "email" note above).
- Cleanup of the temporary ZIP/PNG files `PrepareAndShareButton` and
  `StudyImportService.zipForSharing` create -- there's no single reliable
  "share sheet finished" callback on either platform, so these are left as
  plain OS temp files for the system to reclaim, not deleted immediately
  after a successful share.
