// ShareMenuButton.swift — OpenDicomViewer
//
// Reusable "prepare then share" UI, plus the viewer toolbar's PACS-send/share menu for the
// active panel's series/image/screen-save. Used by MultiPanelContainer.swift's ToolPalette
// (series/image/screenshot scope) and LibraryView.swift (whole-study scope).
//
// IMPORTANT CAVEAT: not compiler-verified, same as every other Swift file in this port.
import SwiftUI

// MARK: - PrepareAndShareButton

/// A button that shows a plain "prepare" affordance first, runs an arbitrary (possibly slow --
/// zipping files, converting a screenshot to PNG) synchronous `prepare` closure on a background
/// queue when tapped, then swaps itself for a real `ShareLink` once that closure returns a file
/// URL. SwiftUI's `ShareLink` has no imperative "trigger from code" API -- it must be tapped
/// directly by the user to present the system share sheet -- so a single-tap "prepare AND share
/// immediately" isn't possible when preparation takes real time, as it does for every use of
/// this component in this app. This two-tap reveal (tap once to prepare, tap the `ShareLink` that
/// then appears) is the straightforward, honest way to combine `ShareLink` with async
/// preparation, used identically everywhere this app needs to share a file.
struct PrepareAndShareButton: View {
    let label: String
    let systemImage: String
    let prepare: () throws -> URL

    @State private var preparedURL: URL?
    @State private var isPreparing = false
    @State private var error: String?

    var body: some View {
        if let preparedURL {
            ShareLink(item: preparedURL) {
                Label(label, systemImage: systemImage)
            }
        } else {
            Button(action: runPrepare) {
                if isPreparing {
                    Label("Preparing…", systemImage: systemImage)
                } else {
                    Label(label, systemImage: systemImage)
                }
            }
            .disabled(isPreparing)
        }
        if let error {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    private func runPrepare() {
        isPreparing = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try prepare()
                DispatchQueue.main.async {
                    isPreparing = false
                    preparedURL = url
                }
            } catch {
                DispatchQueue.main.async {
                    isPreparing = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - PanelShareMenu

/// Viewer toolbar menu (inserted into `ToolPalette`, MultiPanelContainer.swift) offering, for
/// whatever series/image is currently displayed in the active panel: send to the configured PACS
/// node via C-STORE (reusing PACSService.swift/PACSHelper -- see docs/iOS-Build.md's PACS
/// networking section), or share/email the current series, current image, or a "screen save"
/// (PNG export of the panel's current displayed image; see PlatformImageFactory.pngData's doc
/// comment in PlatformCompat.swift for what it does and doesn't capture -- no annotation overlay
/// burn-in yet).
struct PanelShareMenu: View {
    @ObservedObject var model: DICOMModel
    @StateObject private var pacsService = PACSService()

    @State private var sendStatus: String?
    @State private var isSending = false

    var body: some View {
        Menu {
            if let panel = model.activePanel, let context = currentImageContext(panel) {
                Section("Send to PACS") {
                    Button {
                        sendToPACS(files: seriesFileURLs(panel))
                    } label: {
                        Label("Send Current Series", systemImage: "network")
                    }
                    Button {
                        sendToPACS(files: [context.url])
                    } label: {
                        Label("Send Current Image", systemImage: "network")
                    }
                }
                .disabled(isSending)

                Section("Share / Email") {
                    PrepareAndShareButton(label: "Share Current Series", systemImage: "square.and.arrow.up") {
                        try StudyImportService.zipForSharing(files: seriesFileURLs(panel), name: "Series")
                    }
                    PrepareAndShareButton(label: "Share Current Image", systemImage: "square.and.arrow.up") {
                        context.url
                    }
                    if let displayedImage = panel.image, let pngData = PlatformImageFactory.pngData(from: displayedImage) {
                        PrepareAndShareButton(label: "Share Screen Save (PNG)", systemImage: "camera") {
                            let tempURL = FileManager.default.temporaryDirectory
                                .appendingPathComponent("ScreenSave-\(UUID().uuidString).png")
                            try pngData.write(to: tempURL)
                            return tempURL
                        }
                    }
                }

                if let sendStatus {
                    Section {
                        Text(sendStatus)
                    }
                }
            } else {
                Text("No image displayed")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14))
                .frame(width: 32, height: 28)
                .foregroundStyle(.secondary)
        }
        .help("Send to PACS / Share / Screen Save")
    }

    private func currentImageContext(_ panel: PanelState) -> DicomImageContext? {
        guard panel.seriesIndex >= 0, panel.seriesIndex < model.allSeries.count else { return nil }
        let series = model.allSeries[panel.seriesIndex]
        guard panel.imageIndex >= 0, panel.imageIndex < series.images.count else { return nil }
        return series.images[panel.imageIndex]
    }

    private func seriesFileURLs(_ panel: PanelState) -> [URL] {
        guard panel.seriesIndex >= 0, panel.seriesIndex < model.allSeries.count else { return [] }
        return model.allSeries[panel.seriesIndex].images.map(\.url)
    }

    private func sendToPACS(files: [URL]) {
        guard !files.isEmpty else { return }
        isSending = true
        sendStatus = "Sending \(files.count) file(s)…"
        let node = PACSSettingsStore.load()
        Task {
            defer { isSending = false }
            do {
                let count = try await pacsService.storeFiles(node: node, filePaths: files.map(\.path))
                sendStatus = "Sent \(count)/\(files.count) file(s)."
            } catch {
                sendStatus = "Send failed: \(error.localizedDescription)"
            }
        }
    }
}
