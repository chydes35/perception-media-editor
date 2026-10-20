import Foundation

/// A named export recipe. Built-in recipes ship with the app and cannot be changed or deleted.
struct ExportRecipePreset: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var recipe: BatchExportRecipe
    var isBuiltIn = false
}

enum ExportRecipeError: LocalizedError {
    case emptyName
    case nameTooLong
    case nameTaken

    var errorDescription: String? {
        switch self {
        case .emptyName: "Give the recipe a name."
        case .nameTooLong: "Use a recipe name of 60 characters or fewer."
        case .nameTaken: "A built-in recipe already has that name. Choose another."
        }
    }
}

/// Export recipes are user settings, not project data: the same "Web 2048" applies to every shoot,
/// so they live in `UserDefaults` and never change the `.pmedit` schema.
@MainActor
final class ExportRecipeLibrary: ObservableObject {
    private static let recipesKey = "perceptionEditor.exportRecipes.v1"
    private static let selectedKey = "perceptionEditor.exportRecipes.selected.v1"
    static let maximumNameLength = 60

    /// The first recipe reproduces the original batch delivery: full-size JPEG, no sharpening.
    static let builtIns: [ExportRecipePreset] = [
        ExportRecipePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!, name: "Client JPEG, full size",
            recipe: BatchExportRecipe(jpegQuality: 0.92, filenameSuffix: "_edited"), isBuiltIn: true),
        ExportRecipePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000E002")!, name: "Web, 2048 px",
            recipe: BatchExportRecipe(jpegQuality: 0.85, longEdgePixels: 2048, filenameSuffix: "_web",
                                      sharpening: .standard), isBuiltIn: true),
        ExportRecipePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000E003")!, name: "Share, 3000 px HEIC",
            recipe: BatchExportRecipe(jpegQuality: 0.85, longEdgePixels: 3000, filenameSuffix: "_share",
                                      format: .heic10, sharpening: .low), isBuiltIn: true),
        ExportRecipePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000E004")!, name: "Print, 16-bit TIFF",
            recipe: BatchExportRecipe(filenameSuffix: "_print", format: .tiff16), isBuiltIn: true),
    ]

    @Published private(set) var userRecipes: [ExportRecipePreset]
    @Published private(set) var selectedID: UUID

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved: [ExportRecipePreset] = defaults.data(forKey: Self.recipesKey)
            .flatMap { try? JSONDecoder().decode([ExportRecipePreset].self, from: $0) } ?? []
        let user = saved.map { recipe -> ExportRecipePreset in var copy = recipe; copy.isBuiltIn = false; return copy }
        let remembered = defaults.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        let known = Set(Self.builtIns.map(\.id) + user.map(\.id))
        userRecipes = user
        selectedID = remembered.flatMap { known.contains($0) ? $0 : nil } ?? Self.builtIns[0].id
    }

    var all: [ExportRecipePreset] { Self.builtIns + userRecipes }

    var selected: ExportRecipePreset {
        all.first { $0.id == selectedID } ?? Self.builtIns[0]
    }

    func select(_ id: UUID) {
        guard all.contains(where: { $0.id == id }) else { return }
        selectedID = id
        defaults.set(id.uuidString, forKey: Self.selectedKey)
    }

    /// Saves `recipe` under `name`. A user recipe with the same name is replaced; a built-in's name is refused.
    @discardableResult
    func save(_ recipe: BatchExportRecipe, as name: String) throws -> ExportRecipePreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExportRecipeError.emptyName }
        guard trimmed.count <= Self.maximumNameLength else { throw ExportRecipeError.nameTooLong }
        guard !Self.builtIns.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw ExportRecipeError.nameTaken
        }
        try recipe.validate()
        let preset: ExportRecipePreset
        if let index = userRecipes.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            userRecipes[index].recipe = recipe
            preset = userRecipes[index]
        } else {
            preset = ExportRecipePreset(id: UUID(), name: trimmed, recipe: recipe)
            userRecipes.append(preset)
        }
        persist()
        select(preset.id)
        return preset
    }

    func delete(_ id: UUID) {
        guard userRecipes.contains(where: { $0.id == id }) else { return }
        userRecipes.removeAll { $0.id == id }
        persist()
        if selectedID == id { select(Self.builtIns[0].id) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(userRecipes) else { return }
        defaults.set(data, forKey: Self.recipesKey)
    }
}
