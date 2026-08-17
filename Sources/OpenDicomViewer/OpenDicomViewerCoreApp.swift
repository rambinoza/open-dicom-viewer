// OpenDicomViewerCoreApp.swift
// OpenDicomViewerCore
//
// Shared SwiftUI App scene. Configures the main window with a hidden titlebar
// and registers menu bar commands for layout switching, view operations
// (window/level, transforms, overlays), MPR mode, and synchronized scrolling.
//
// This type lives in the OpenDicomViewerCore library target (shared by macOS
// and, eventually, iOS) rather than in a platform executable target, because a
// bare SwiftPM `.executableTarget` cannot produce an installable iOS app
// bundle -- only a real Xcode "App" target can. So each platform gets a thin
// executable shim with its own `@main` entry point that forwards to this
// type's `body`. See Sources/OpenDicomViewerMacApp/main.swift for the macOS
// shim, and docs/iOS-Build.md for how the iOS Xcode target should wire up to
// this package's `OpenDicomViewerCore` library product.
//
// `@main` was intentionally removed from this type -- it has no effect inside
// a library target (SwiftPM only looks for `@main` within the files of the
// executable target actually being built), and was previously only doing
// anything because this file lived directly inside the (now-split) executable
// target.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

public struct OpenDicomViewerCoreApp: App {
    @StateObject private var model = DICOMModel()
    @StateObject private var updateChecker = UpdateChecker()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    // Auto-open directory if passed via --benchmark /path
                    if let benchIdx = CommandLine.arguments.firstIndex(of: "--benchmark"),
                       benchIdx + 1 < CommandLine.arguments.count {
                        let path = CommandLine.arguments[benchIdx + 1]
                        let url = URL(fileURLWithPath: path)
                        model.load(url: url)
                    } else {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await updateChecker.checkForUpdates()
                    }
                }
                .alert(
                    updateAlertTitle,
                    isPresented: $updateChecker.showUpdateAlert
                ) {
                    updateAlertButtons
                } message: {
                    Text(updateAlertMessage)
                }
        }
        // `.hiddenTitleBar` (WindowStyle) only exists on macOS; there's no
        // titlebar concept to hide on iOS, so this whole modifier is gated.
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    Task { await updateChecker.checkForUpdates(userInitiated: true) }
                }
            }

            // `model.openFolder()` (NSOpenPanel) only exists on macOS -- see
            // DICOMModel.swift. The iOS entry point should offer its own
            // "Open" affordance from the view layer (`.fileImporter`) as part
            // of the touch-native iOS interaction layer work.
            #if os(macOS)
            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    model.openFolder()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            #endif

            CommandGroup(after: .toolbar) {
                // ─ Window/Level ─
                Button("Auto Window/Level (A)") {
                    if let panel = model.activePanel {
                        model.autoWindowLevelForPanel(panel)
                    }
                }

                Button("Invert (I)") {
                    model.invertForPanel(model.activePanel)
                }

                Divider()

                // ─ Transform ─
                Button("Fit to Window (F)") {
                    model.fitToWindowForPanel(model.activePanel)
                }

                Button("Reset View (R)") {
                    model.resetViewForPanel(model.activePanel)
                }

                Divider()

                Button("Rotate Clockwise 90° (])") {
                    model.rotateClockwiseForPanel(model.activePanel)
                }

                Button("Rotate Counter-Clockwise 90° ([)") {
                    model.rotateCounterClockwiseForPanel(model.activePanel)
                }

                Button("Flip Horizontal (H)") {
                    model.flipHorizontalForPanel(model.activePanel)
                }

                Button("Flip Vertical") {
                    model.flipVerticalForPanel(model.activePanel)
                }

                Divider()

                // ─ Overlays ─
                Toggle("Cross-Reference Lines (X)", isOn: $model.showCrossReference)

                Toggle("DICOM Tags Inspector (T)", isOn: $model.showTags)
            }

            CommandMenu("Layout") {
                Button("Single Panel") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.single) }
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Side by Side") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoHorizontal) }
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Stacked") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoVertical) }
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Four Panels") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.quad) }
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button("MPR Layout") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setupMPRLayout() }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()

                Toggle("Synchronized Scrolling", isOn: $model.synchronizedScrolling)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }

            CommandMenu("Tools") {
                Button("Select (V)") { model.activeTool = .select }
                Button("Pan (P)") { model.activeTool = .pan }
                Button("Window/Level (W)") { model.activeTool = .windowLevel }
                Button("Zoom (Z)") { model.activeTool = .zoom }

                Divider()

                Button("ROI W/L (O)") { model.activeTool = .roiWL }
                Button("ROI Stats (S)") { model.activeTool = .roiStats }

                Divider()

                Button("Ruler (D)") { model.activeTool = .ruler }
                Button("Angle (N)") { model.activeTool = .angle }

                Divider()

                Button("Eraser (E)") { model.activeTool = .eraser }
            }

            CommandGroup(replacing: .help) {
                Button("OpenDicomViewer Help") {
                    model.showHelp = true
                }
            }
        }
    }

    private var updateAlertTitle: String {
        switch updateChecker.state {
        case .updateAvailable:
            return "Update Available"
        case .upToDate:
            return "You're Up to Date"
        default:
            return ""
        }
    }

    private var updateAlertMessage: String {
        switch updateChecker.state {
        case .updateAvailable(let version, let notes, _):
            return "Version \(version) is available (current: \(updateChecker.currentVersion)).\n\n\(String(notes.prefix(300)))"
        case .upToDate:
            return "OpenDicomViewer \(updateChecker.currentVersion) is the latest version."
        default:
            return ""
        }
    }

    @ViewBuilder
    private var updateAlertButtons: some View {
        switch updateChecker.state {
        case .updateAvailable(let version, _, let url):
            Button("Download") { updateChecker.openDownload(url) }
            Button("Skip This Version") { updateChecker.skipVersion(version) }
            Button("Later", role: .cancel) { }
        case .upToDate:
            Button("OK", role: .cancel) { }
        default:
            Button("OK", role: .cancel) { }
        }
    }
}
