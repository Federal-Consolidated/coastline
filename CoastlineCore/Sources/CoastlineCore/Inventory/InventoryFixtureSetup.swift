import Foundation

extension Inventory {
    /// Resolve job-specific workholding without changing the library's reusable defaults.
    /// Saved geometry and mechanical state stay pinned; availability comes from the live
    /// inventory. A removed fixture is never resurrected by its saved job snapshot.
    public func forFixtureSetup(_ setup: Setup) -> Inventory {
        let saved = Dictionary((setup.fixtureAssemblies ?? []).map { ($0.id, $0) },
                               uniquingKeysWith: { _, latest in latest })
        let selected = setup.selectedFixtureIDs.map { Set($0) }
        var result = self
        result.fixtures = fixtures.compactMap { owned in
            guard selected?.contains(owned.id) ?? true else { return nil }
            var fixture = saved[owned.id] ?? owned
            fixture.quantity = owned.quantity
            return fixture
        }
        return result
    }
}
