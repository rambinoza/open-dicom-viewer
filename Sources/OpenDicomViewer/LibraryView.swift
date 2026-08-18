// LibraryView.swift — OpenDicomViewer
//
// Study library: browse every locally-imported or PACS-retrieved study (StudyDatabase.swift),
// import more from a folder or ZIP archive (StudyImportService.swift), delete a study, send a
// whole study to a configured PACS via C-STORE, or share/email it as a single ZIP. Presented as
// a sheet from SidebarView's toolbar (ContentView.swift), on both platforms -- like
// PACSBrowserView.swift, this is plain SwiftUI with no AppKit/UIKit dependency.
//
// IMPORTANT CAVEAT: not compiler-verified, same as every other Swift file in this port.
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: DICOMModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var pacsService = PACSService()

    @State private var studies: [StudyRecord] = []
    @State private var statusMessage: String = ""
    @State private var errorMessage: String?
    @State private var isImporting = false

    @State private var showingFolderImporter = false
    @State private var showingZipImporter = false

    @State private var studyPendingDeletion: StudyRecord?
    @State private var sendingStudyUID: String?

    var body: some View {
        NavigationStack {
            Group {
                if studies.isEmpty {
                    ContentUnavailableView(
                        "No Studies Yet",
                        systemImage: "tray",
                        description: Text("Import a folder or ZIP archive, or retrieve a study from a PACS, to see it here.")
                    )
                } else {
                    List {
                        ForEach(studies) { study in
                            studyRow(study)
                        }
                    }
                }
            }
            .navigationTitle("Study Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showingFolderImporter = true
                    } label: {
                        Label("Import Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showingZipImporter = true
                    } label: {
                        Label("Import ZIP", systemImage: "doc.zipper")
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFolderImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result) { url in try StudyImportService.importFolder(from: url) }
            }
            .fileImporter(
                isPresented: $showingZipImporter,
                allowedContentTypes: [.zip],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result) { url in try StudyImportService.importZip(from: url) }
            }
            .overlay {
                if isImporting {
                    ProgressView("Importing…")
                        .padding()
                        .background(.regularMaterial)
                        .cornerRadius(8)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !statusMessage.isEmpty || errorMessage != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        if !statusMessage.isEmpty {
                            Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                        }
                        if let errorMessage {
                            Text(errorMessage).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.thinMaterial)
                }
            }
            .alert(
                "Delete Study?",
                isPresented: Binding(
                    get: { studyPendingDeletion != nil },
                    set: { if !$0 { studyPendingDeletion = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let study = studyPendingDeletion {
                        StudyImportService.deleteStudy(study)
                        refresh()
                    }
                    studyPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { studyPendingDeletion = nil }
            } message: {
                if let study = studyPendingDeletion {
                    Text("This permanently deletes \(study.patientName.isEmpty ? "this study" : "\"\(study.patientName)\"") (\(study.numberOfInstances) image(s)) from this device.")
                }
            }
        }
        .onAppear { refresh() }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
    }

    @ViewBuilder
    private func studyRow(_ study: StudyRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(study.patientName.isEmpty ? "Unnamed Patient" : study.patientName)
                    .font(.headline)
                Spacer()
                Text(study.formattedStudyDate)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !study.studyDescription.isEmpty {
                Text(study.studyDescription).font(.subheadline)
            }
            HStack(spacing: 12) {
                if !study.modalities.isEmpty {
                    Text(study.modalities)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
                Label(study.source == "pacs" ? "PACS" : "Local", systemImage: study.source == "pacs" ? "network" : "internaldrive")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(study.numberOfInstances) image(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if sendingStudyUID == study.studyInstanceUID {
                    ProgressView()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(study) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                studyPendingDeletion = study
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button { open(study) } label: {
                Label("Open", systemImage: "eye")
            }
            Button { sendToPACS(study) } label: {
                Label("Send to PACS", systemImage: "network")
            }
            PrepareAndShareButton(label: "Share / Email", systemImage: "square.and.arrow.up") {
                let folder = try StudyImportService.absoluteURL(for: study)
                let name = study.patientName.isEmpty ? study.studyInstanceUID : study.patientName
                return try StudyImportService.zipForSharing(folder: folder, name: name)
            }
            Divider()
            Button(role: .destructive) { studyPendingDeletion = study } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding(.vertical, 4)
    }

    private func refresh() {
        studies = StudyDatabase.shared.allStudies()
    }

    private func open(_ study: StudyRecord) {
        guard let url = try? StudyImportService.absoluteURL(for: study) else { return }
        model.load(url: url)
        dismiss()
    }

    private func handleImport(_ result: Result<[URL], Error>, _ importAction: @escaping (URL) throws -> URL) {
        errorMessage = nil
        switch result {
        case .success(let urls):
            guard let sourceURL = urls.first else { return }
            isImporting = true
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    _ = try importAction(sourceURL)
                    DispatchQueue.main.async {
                        isImporting = false
                        statusMessage = "Import complete."
                        refresh()
                    }
                } catch {
                    DispatchQueue.main.async {
                        isImporting = false
                        errorMessage = error.localizedDescription
                    }
                }
            }
        case .failure(let error):
            errorMessage = "Could not import: \(error.localizedDescription)"
        }
    }

    private func sendToPACS(_ study: StudyRecord) {
        errorMessage = nil
        sendingStudyUID = study.studyInstanceUID
        let node = PACSSettingsStore.load()
        Task {
            defer { sendingStudyUID = nil }
            do {
                let folder = try StudyImportService.absoluteURL(for: study)
                let files = filesInFolder(folder)
                guard !files.isEmpty else {
                    errorMessage = "No files found for this study."
                    return
                }
                let count = try await pacsService.storeFiles(node: node, filePaths: files.map(\.path))
                statusMessage = "Sent \(count)/\(files.count) file(s) to \(node.host)."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func filesInFolder(_ folder: URL) -> [URL] {
        var results: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isDirectory {
                    results.append(fileURL)
                }
            }
        }
        return results
    }
}
