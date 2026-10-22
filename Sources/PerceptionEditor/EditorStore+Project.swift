import Foundation

enum ProjectSaveState: Equatable {
    case unsaved
    case pending
    case saved
    case failed(String)
}

extension EditorStore {
    var projectSaveState: ProjectSaveState {
        if let projectSaveError { return .failed(projectSaveError) }
        guard projectURL != nil else { return .unsaved }
        return hasUnsavedChanges ? .pending : .saved
    }

    /// Shared by explicit saves and autosave; only a successful write advances the snapshot.
    @discardableResult
    func saveProject(to destination: URL, announce: Bool = true) -> Bool {
        do {
            if let problem = IngestService.volumeProblem(for: destination) {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: problem])
            }
            try document.save(project, to: destination)
            copyReferencedLUTs(nextTo: destination)
            projectURL = destination
            lastSavedProject = project
            projectSaveError = nil
            if announce { statusMessage = "Saved \(destination.lastPathComponent)" }
            return true
        } catch {
            projectSaveError = error.localizedDescription
            if announce { statusMessage = "Project save failed" }
            return false
        }
    }
}
