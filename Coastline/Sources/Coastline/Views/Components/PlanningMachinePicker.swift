import CoastlineCore
import SwiftUI

/// The job's machine, kept distinct from the profile being browsed and the physical link.
struct PlanningMachinePicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            ForEach(app.machineProfiles.packages, id: \.definition.reference) { package in
                Button {
                    Task {
                        do { await app.selectPlanningMachine(try PlanningMachineReference(definition: package.definition)) }
                        catch { app.errorMessage = error.localizedDescription }
                    }
                } label: {
                    if app.planningMachineReference.definition == package.definition {
                        Label("\(package.definition.name) · r\(package.definition.revision)", systemImage: "checkmark")
                    } else {
                        Text("\(package.definition.name) · r\(package.definition.revision)")
                    }
                }
            }
            if app.planningMachineReference.isLegacy {
                Label("Legacy Desktop CNC", systemImage: "checkmark")
            }
            Divider()
            Button("Machine Profiles…") { app.page = .machine }
        } label: {
            Label(app.isSwitchingPlanningMachine ? "Loading machine…" : app.planningMachineTitle, systemImage: "gearshape.2")
                .lineLimit(1)
        }
        .disabled(!app.canChangePlanningMachine)
        .help("Machine for this job. Changing it clears generated toolpaths.")
        .accessibilityLabel("Job machine: \(app.planningMachineTitle)")
        .task { await app.machineProfiles.reload() }
    }
}
