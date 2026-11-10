import CoastlineCore
import SwiftUI

/// One-time setup semantics for an imported, assembled jig. Dimensions stay in the app's
/// usual unit-aware fields; the CAD is never altered to invent an adjustable mechanism.
struct FixturePlanningSection: View {
    @Binding var fixture: Fixture
    @Environment(AppModel.self) private var app
    var title = "Automatic setup planning"

    var body: some View {
        Section {
            Toggle("Consider this fixture when planning", isOn: Binding(
                get: { fixture.planning?.enabled ?? false }, set: { enabled in
                    var p = fixture.planning ?? FixturePlanningProfile()
                    p.enabled = enabled
                    fixture.planning = p
                }))
            if fixture.planning != nil {
                if let stock = app.stock {
                    Button("Use This Job's Stock Dimensions") {
                        let size = app.setup.stockSize(stock)
                        fixture.planning?.stockSize = Vec3(size.x, size.y, size.z)
                        fixture.planning?.gripDefinitionReviewed = false
                    }.controlSize(.small)
                }
                FixturePlanningFields(profile: Binding(get: { fixture.planning! }, set: { fixture.planning = $0 }))
            }
        } header: {
            Text(title)
        } footer: {
            Text("Use a closed-solid STEP assembly containing the fixture and hardware, without the stock or part. Define the stock and grip for this assembled state once. Different jaw or screw positions need a matching model/entry; STEP geometry alone does not describe clamping force.")
        }
        .onChange(of: fixture.modelPath) { _, _ in invalidateReview() }
        .onChange(of: fixture.height) { _, _ in invalidateReview() }
        .onChange(of: fixture.clampAxis) { _, _ in invalidateReview() }
        .onChange(of: fixture.gripRange) { _, _ in invalidateReview() }
    }

    private func invalidateReview() {
        guard fixture.planning != nil else { return }
        fixture.planning?.gripDefinitionReviewed = false
    }
}

private struct FixturePlanningFields: View {
    @Binding var profile: FixturePlanningProfile

    var body: some View {
        Group {
            Text("Stock held by this assembly").font(.callout.weight(.semibold))
            NumberField(title: "Stock X · up", value: $profile.stockSize.x)
            NumberField(title: "Stock Y · across", value: $profile.stockSize.y)
            NumberField(title: "Stock Z · depth", value: $profile.stockSize.z)
            DisclosureGroup("Advanced CAD datum and orientation") {
                Text("Stock-face centre in the original model's coordinates. Use the movement controls above to adjust this visually.")
                    .font(.caption).foregroundStyle(.secondary)
                NumberField(title: "CAD datum X", value: $profile.datum.x)
                NumberField(title: "CAD datum Y", value: $profile.datum.y)
                NumberField(title: "CAD datum Z", value: $profile.datum.z)
                Picker("CAD face toward spindle", selection: $profile.facing) {
                    ForEach(Setup.Facing.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Turn around spindle", selection: $profile.spin) {
                    ForEach(0..<4) { Text("\($0 * 90)°").tag($0) }
                }
            }
            NumberField(title: "Stock face past table edge", value: $profile.facePastTable)
            Toggle("Suitable for roughing and facing", isOn: $profile.allowsRoughing)
            Text("Grip / support patches").font(.callout.weight(.semibold))
            Text("Points in stock work coordinates: X up, Y across, Z from 0 at the front face toward negative depth. Each patch must remain material throughout its assigned cuts.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($profile.contacts) { $contact in
                DisclosureGroup("Grip patch \((profile.contacts.firstIndex { $0.id == contact.id } ?? 0) + 1)") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Contact patch").font(.caption.weight(.semibold))
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") {
                            profile.gripDefinitionReviewed = false
                            profile.contacts.removeAll { $0.id == contact.id }
                        }.buttonStyle(.borderless)
                    }
                    NumberField(title: "Contact X", value: $contact.point.x)
                    NumberField(title: "Contact Y", value: $contact.point.y)
                    NumberField(title: "Contact Z", value: $contact.point.z)
                    Picker("Contact face normal", selection: Binding(get: { contact.normal ?? .z }, set: { contact.normal = $0 })) {
                        ForEach(FixturePlanningProfile.Contact.Normal.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    NumberField(title: "Patch radius", value: $contact.radius)
                }
                }
            }
            Button("Add Grip / Support Patch", systemImage: "plus") {
                profile.gripDefinitionReviewed = false
                profile.contacts.append(.init())
            }
            Toggle("Grip, mounting and cutting-load definition reviewed", isOn: $profile.gripDefinitionReviewed)
            ForEach(profile.definitionIssues, id: \.self) { issue in
                Text(issue).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: profile) { old, new in
            var a = old, b = new
            a.gripDefinitionReviewed = false; b.gripDefinitionReviewed = false
            if a != b && new.gripDefinitionReviewed { profile.gripDefinitionReviewed = false }
        }
    }
}

