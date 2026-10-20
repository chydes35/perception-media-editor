import SwiftUI

/// The recipe controls in the Export workspace: pick a saved recipe, adjust it, save it under a name.
struct ExportRecipeEditor: View {
    @ObservedObject var library: ExportRecipeLibrary
    @Binding var recipe: BatchExportRecipe
    var report: (String) -> Void

    @State private var isNamingRecipe = false
    @State private var recipeName = ""

    private static let longEdgeChoices = [0, 1080, 1600, 2048, 3000, 4000]

    private var longEdgeSelection: Binding<Int> {
        Binding(
            get: { recipe.longEdgePixels ?? 0 },
            set: { recipe.longEdgePixels = $0 == 0 ? nil : $0 }
        )
    }

    private var longEdgeOptions: [Int] {
        let current = recipe.longEdgePixels ?? 0
        return Self.longEdgeChoices.contains(current) ? Self.longEdgeChoices : (Self.longEdgeChoices + [current]).sorted()
    }

    private var isModified: Bool { recipe != library.selected.recipe }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Recipe", selection: Binding(
                    get: { library.selectedID },
                    set: { library.select($0); recipe = library.selected.recipe }
                )) {
                    ForEach(library.all) { preset in Text(preset.name).tag(preset.id) }
                }
                .accessibilityIdentifier("export-recipe-picker")
                if isModified { Text("Modified").font(.caption).foregroundStyle(.orange) }
            }

            Picker("Format", selection: $recipe.format) {
                ForEach(ExportFormat.allCases) { format in Text(format.title).tag(format) }
            }
            .accessibilityIdentifier("export-format")

            if recipe.format.usesQuality {
                HStack {
                    Text("Quality")
                    Slider(value: $recipe.jpegQuality, in: 0.5...1, step: 0.05)
                    Text("\(Int((recipe.jpegQuality * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Picker("Long edge", selection: longEdgeSelection) {
                ForEach(longEdgeOptions, id: \.self) { edge in
                    Text(edge == 0 ? "Full resolution" : "\(edge.formatted()) px").tag(edge)
                }
            }

            Picker("Output sharpening", selection: $recipe.sharpening) {
                ForEach(OutputSharpening.allCases) { level in Text(level.title).tag(level) }
            }
            .pickerStyle(.segmented)

            Divider()

            TextField("Copyright, such as © 2026 Perception Media", text: $recipe.metadata.copyright)
                .textFieldStyle(.roundedBorder)
            TextField("Creator", text: $recipe.metadata.creator)
                .textFieldStyle(.roundedBorder)
            Toggle("Remove location and camera serial number", isOn: $recipe.metadata.removePrivateData)
                .accessibilityIdentifier("export-remove-private-data")

            HStack {
                Text("Filename suffix")
                TextField("_edited", text: $recipe.filenameSuffix)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Save Recipe…") {
                    recipeName = library.selected.isBuiltIn ? "" : library.selected.name
                    isNamingRecipe = true
                }
                Button("Delete Recipe", role: .destructive) {
                    library.delete(library.selectedID)
                    recipe = library.selected.recipe
                }
                .disabled(library.selected.isBuiltIn)
            }

            Text("sRGB, upright, with the camera's exposure data. Existing files receive a numbered name. Original photos are protected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .alert("Save Recipe", isPresented: $isNamingRecipe) {
            TextField("Name", text: $recipeName)
            Button("Save") {
                do { try library.save(recipe, as: recipeName) } catch { report(error.localizedDescription) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved recipes are available for every project.")
        }
    }
}
