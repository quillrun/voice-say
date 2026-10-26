// Swift Testing port of the CategoryStore tests. Exercises the real
// `@testable import VoiceSay` type against a throwaway UserDefaults suite so it
// never touches the app's real defaults.
//
// `.serialized` + `@MainActor`: CategoryStore is a @MainActor type. Each test
// already isolates its own uniquely-named UserDefaults suite, so parallel runs
// would be safe — `.serialized` is the conservative hedge.

import Foundation
import Testing
@testable import VoiceSay

@Suite("CategoryStore", .serialized)
@MainActor
struct CategoryStoreTests {

    /// A fresh, empty, uniquely-named defaults suite per test.
    private func freshDefaults() -> UserDefaults { TestSupport.freshDefaults() }

    @Test("normalizedTag maps 'Series A' → series-a and trims + lowercases")
    func normalizes() {
        #expect(CategoryStore.normalizedTag("Series A") == "series-a")
        #expect(CategoryStore.normalizedTag("  My Topic ") == "my-topic")
    }

    @Test("seeds the 4 built-in categories in canonical order: History · New · Rendering · Says")
    func seedsBuiltins() {
        let store = CategoryStore(defaults: freshDefaults())
        // A fresh install has the 4 built-ins and nothing else.
        #expect(store.categories.count == 4)
        #expect(store.categories.first?.id == "history")
        #expect(store.categories.first?.isAll == true)
        #expect(store.categories.count > 1 && store.categories[1].id == "new")
        #expect(store.categories.count > 2 && store.categories[2].id == "rendering")

        let says = store.categories.first { $0.id == "says" }
        #expect(store.categories.count > 3 && store.categories[3].id == "says")
        #expect(says?.kind == "say")        // kind-backed
        #expect(says?.isAll == false)       // not the all-view
        #expect(says?.tag == nil)           // no backing tag
        // The 4 built-ins lead in canonical order.
        #expect(Array(store.categories.prefix(4).map(\.id)) == ["history", "new", "rendering", "says"])
    }

    @Test("addCategory creates, dedupes by normalized tag, and rejects empty names")
    func addCreateDedupeReject() {
        let store = CategoryStore(defaults: freshDefaults())

        // Baseline = the 4 built-ins.
        let baseline = store.categories.count
        #expect(baseline == 4)

        let created = store.addCategory(name: "My Topic")
        #expect(created?.tag == "my-topic")
        #expect(created?.kind == nil)        // user category, not kind-backed
        #expect(store.categories.count == baseline + 1)

        let dupe = store.addCategory(name: "my topic")   // normalizes to the same tag
        #expect(store.categories.count == baseline + 1)  // no new row
        #expect(dupe?.tag == "my-topic")                 // returns the existing one

        #expect(store.addCategory(name: "   ") == nil)   // empty rejected
    }

    @Test("remove drops user categories but never the built-ins (History, Says)")
    func removeProtectsBuiltins() {
        let store = CategoryStore(defaults: freshDefaults())
        _ = store.addCategory(name: "My Topic")

        store.removeCategory("my-topic")
        #expect(!store.categories.contains { $0.id == "my-topic" })

        store.removeCategory("history")
        #expect(store.categories.contains { $0.id == "history" })

        store.removeCategory("says")
        #expect(store.categories.contains { $0.id == "says" })
    }

    @Test("user categories persist across a reopen of the same suite")
    func persistsAcrossReopen() {
        let defaults = freshDefaults()
        let store = CategoryStore(defaults: defaults)
        _ = store.addCategory(name: "Persisted")

        let reopened = CategoryStore(defaults: defaults)
        #expect(reopened.categories.contains { $0.tag == "persisted" })
        #expect(reopened.categories.first?.id == "history")
        #expect(reopened.categories.count > 3 && reopened.categories[3].id == "says")
    }
}
