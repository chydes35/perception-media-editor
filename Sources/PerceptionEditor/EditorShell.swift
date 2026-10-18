import SwiftUI

/// Accent used for selected states, from the approved mockups (teal to blue).
enum EditorAccent {
    static let teal = Color(red: 0x19 / 255, green: 0xD3 / 255, blue: 0xC5 / 255)
    static let blue = Color(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255)
    static let gradient = LinearGradient(colors: [teal, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Big rail button: stacked icon over title, accent gradient when selected.
struct RailButtonStyle: ButtonStyle {
    let isSelected: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: EditorMetrics.railButtonHeight)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(EditorAccent.gradient) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
                    .opacity(isSelected || isHovering || configuration.isPressed ? 1 : 0.55)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: isSelected ? 0 : 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { isHovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Top-bar button. Photo and Video are wide; Agents and Back use the compact form.
struct CategoryButtonStyle: ButtonStyle {
    let isSelected: Bool
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, compact ? 12 : 22)
            .frame(minHeight: EditorMetrics.categoryButtonHeight)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                Capsule()
                    .fill(isSelected ? AnyShapeStyle(EditorAccent.gradient) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
            }
            .overlay { Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: isSelected ? 0 : 1) }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

struct CategoryBar: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PERCEPTION MEDIA")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(.secondary)
                TextField("Project name", text: $store.project.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .frame(width: 270)
            }

            Spacer()

            HStack(spacing: 10) {
                ForEach(EditorCategory.allCases) { category in
                    let isSelected = store.workspace != .agents && store.category == category
                    Button {
                        store.requestCategoryChange(to: category)
                    } label: {
                        Label(category.rawValue, systemImage: category == .photo ? "photo" : "film")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(CategoryButtonStyle(isSelected: isSelected))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            Spacer()

            if store.workspace == .agents {
                Button {
                    store.closeAgents()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(CategoryButtonStyle(isSelected: false, compact: true))
                .help("Return to the editor")
            }
            Button {
                store.openAgents()
            } label: {
                Label("Agents", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(CategoryButtonStyle(isSelected: store.workspace == .agents, compact: true))
            .help("Workflow agents")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

struct StepRail: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        VStack(spacing: 10) {
            ForEach(store.category.steps) { step in
                let isSelected = step.workspace == store.workspace
                Button {
                    store.requestStepChange(step)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: step.symbol)
                            .font(.system(size: 20, weight: .medium))
                        Text(step.title)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(RailButtonStyle(isSelected: isSelected))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: EditorMetrics.railWidth)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}
