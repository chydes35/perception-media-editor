import Foundation

enum ProjectDocumentError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "This project uses unsupported schema version \(version)."
        }
    }
}

struct ProjectDocument {
    static let fileExtension = "pmedit"

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func data(for project: EditorProject) throws -> Data {
        var current = project
        current.updatedAt = .now
        return try encoder.encode(current)
    }

    func project(from data: Data) throws -> EditorProject {
        let project = try decoder.decode(EditorProject.self, from: data)
        guard project.schemaVersion <= EditorProject.currentSchemaVersion else {
            throw ProjectDocumentError.unsupportedSchema(project.schemaVersion)
        }
        return project
    }

    func save(_ project: EditorProject, to url: URL) throws {
        try data(for: project).write(to: url, options: .atomic)
    }

    func load(from url: URL) throws -> EditorProject {
        try project(from: Data(contentsOf: url))
    }
}
