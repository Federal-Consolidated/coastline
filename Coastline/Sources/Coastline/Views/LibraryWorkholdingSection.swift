import CoastlineCore
import SwiftUI

struct LibraryWorkholdingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Setups in this plan") {
            if model.setup.planFromFixtureLibrary {
                if let plan = model.libraryWorkholdingPlan {
                    ForEach(plan.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.warning) }
                    ForEach(plan.steps) { step in
                        VStack(alignment: .leading, spacing: 5) {
                            Button { model.inspectLibraryStep(step) } label: {
                                Label(step.title, systemImage: "eye").font(.callout.weight(.semibold))
                            }.buttonStyle(.borderless)
                            Text((step.side >= 2 ? SetupSide.words(step.side).capitalized : "Side \(step.side == 0 ? "A" : "B")") + " · " + step.operations.joined(separator: " → "))
                                .font(.caption)
                            let tools = model.programs.filter { $0.workholdingStep?.id == step.id }.map(\.tool.name)
                            Text("Tools: " + Array(Set(tools)).sorted().joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Setup details") {
                                Text(step.instructions).font(.caption).foregroundStyle(.secondary)
                                ForEach(step.reasons, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }.font(.caption)
                            Toggle("Placement and secure grip reviewed", isOn: Binding(
                                get: { model.libraryWorkholdingPlan?.steps.first { $0.id == step.id }?.reviewed ?? false },
                                set: { model.reviewLibraryStep(step.id, reviewed: $0) }))
                                .font(.caption)
                        }.padding(.vertical, 4)
                    }
                    if plan.complete {
                        Text("\(plan.steps.count) setups cover the planned cuts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Build the plan to see its setups here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Change Workholding", systemImage: "arrow.left") { model.enter(.setups) }
            }
        }
    }
}
