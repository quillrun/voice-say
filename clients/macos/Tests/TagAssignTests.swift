// TagAssignTests — Swift Testing coverage for SAY-02 and SAY-03 pure cores.
//
// Covered:
//   • TagAssignCore.saveEnabled — set-equality diff logic
//   • TagAssignCore.applySingleCategory — single-category collapse rule
//   • TagAssignCore.tagListExcludingCategories — category-tag exclusion
//   • CategoryStore.renameCategory — guard logic
//   • TagColorStore round-trip — persist + reload

import Foundation
import SwiftUI
import Testing
@testable import VoiceSay

// MARK: - SAY-02: Save-enable set-equality logic

@Suite("TagAssignCore.saveEnabled", .serialized)
struct SaveEnabledTests {

    @Test("equal sets → Save disabled")
    func equalSets() {
        let base: Set<String> = ["news", "completed"]
        #expect(!TagAssignCore.saveEnabled(baseline: base, current: base))
    }

    @Test("adding a tag → Save enabled")
    func addTag() {
        let base: Set<String> = ["news"]
        let current: Set<String> = ["news", "learn"]
        #expect(TagAssignCore.saveEnabled(baseline: base, current: current))
    }

    @Test("removing a tag → Save enabled")
    func removeTag() {
        let base: Set<String> = ["news", "learn"]
        let current: Set<String> = ["news"]
        #expect(TagAssignCore.saveEnabled(baseline: base, current: current))
    }

    @Test("reverting back to baseline → Save disabled again")
    func revertToBaseline() {
        let base: Set<String> = ["news", "learn"]
        var current = base
        current.insert("hardware")
        // Staged differs
        #expect(TagAssignCore.saveEnabled(baseline: base, current: current))
        // Revert
        current.remove("hardware")
        #expect(!TagAssignCore.saveEnabled(baseline: base, current: current))
    }

    @Test("empty baseline, empty current → Save disabled")
    func bothEmpty() {
        #expect(!TagAssignCore.saveEnabled(baseline: [], current: []))
    }

    @Test("order doesn't matter — set equality not sequence equality")
    func orderIndependent() {
        let base: Set<String> = ["a", "b", "c"]
        let current: Set<String> = ["c", "a", "b"]
        #expect(!TagAssignCore.saveEnabled(baseline: base, current: current))
    }
}

// MARK: - SAY-02: Single-category collapse rule

@Suite("TagAssignCore.applySingleCategory", .serialized)
struct SingleCategoryTests {

    private let allCatTags: Set<String> = ["series-a-v3", "my-topic", "briefing"]

    @Test("selecting a category strips all other category tags from staged")
    func stripOthers() {
        let staged: Set<String> = ["news", "series-a-v3", "learn"]
        let result = TagAssignCore.applySingleCategory(
            staged: staged, chosen: "my-topic", allCategoryTags: allCatTags
        )
        // series-a-v3 stripped; my-topic added; non-category tags preserved
        #expect(result.contains("my-topic"))
        #expect(!result.contains("series-a-v3"))
        #expect(!result.contains("briefing"))
        #expect(result.contains("news"))
        #expect(result.contains("learn"))
    }

    @Test("selecting a category when none was set just inserts it")
    func insertWhenNone() {
        let staged: Set<String> = ["news", "learn"]
        let result = TagAssignCore.applySingleCategory(
            staged: staged, chosen: "my-topic", allCategoryTags: allCatTags
        )
        #expect(result.contains("my-topic"))
        #expect(result.contains("news"))
        #expect(result.contains("learn"))
        #expect(!result.contains("series-a-v3"))
    }

    @Test("selecting the same category that's already set is idempotent")
    func idempotent() {
        let staged: Set<String> = ["news", "my-topic"]
        let result = TagAssignCore.applySingleCategory(
            staged: staged, chosen: "my-topic", allCategoryTags: allCatTags
        )
        #expect(result == staged)
    }

    @Test("clearCategory removes the tag from staged")
    func clearCategory() {
        let staged: Set<String> = ["news", "my-topic"]
        let result = TagAssignCore.clearCategory(staged: staged, tag: "my-topic")
        #expect(!result.contains("my-topic"))
        #expect(result.contains("news"))
    }
}

// MARK: - SAY-02: Category-tag exclusion from the tag list

@Suite("TagAssignCore.tagListExcludingCategories", .serialized)
struct TagListExclusionTests {

    @Test("category backing tags are excluded from the tag list")
    func categoryTagsExcluded() {
        let universe = ["news", "series-a-v3", "learn", "briefing"]
        let declared: [String] = []
        let catTags: Set<String> = ["series-a-v3", "briefing"]
        let result = TagAssignCore.tagListExcludingCategories(
            universe: universe, declared: declared, categoryTags: catTags
        )
        #expect(!result.contains("series-a-v3"))
        #expect(!result.contains("briefing"))
        #expect(result.contains("news"))
        #expect(result.contains("learn"))
    }

    @Test("declared tags appear in the list if not a category tag")
    func declaredTagsIncluded() {
        let universe: [String] = ["news"]
        let declared = ["my-tag"]
        let catTags: Set<String> = []
        let result = TagAssignCore.tagListExcludingCategories(
            universe: universe, declared: declared, categoryTags: catTags
        )
        #expect(result.contains("my-tag"))
        #expect(result.contains("news"))
    }

    @Test("result is sorted")
    func resultSorted() {
        let universe = ["zebra", "apple", "mango"]
        let result = TagAssignCore.tagListExcludingCategories(
            universe: universe, declared: [], categoryTags: []
        )
        #expect(result == result.sorted())
    }

    @Test("no duplicates between universe and declared")
    func noDuplicates() {
        let universe = ["news", "learn"]
        let declared = ["news", "extra"]
        let result = TagAssignCore.tagListExcludingCategories(
            universe: universe, declared: declared, categoryTags: []
        )
        let unique = Set(result)
        #expect(result.count == unique.count)
    }
}

// MARK: - SAY-02: Create-tag eligibility (assign window can declare new tags)

@Suite("TagAssignCore.canCreateTag", .serialized)
struct CanCreateTagTests {

    @Test("a fresh name not in use is creatable")
    func freshName() {
        #expect(TagAssignCore.canCreateTag(
            normalizedQuery: "physics",
            universe: ["news", "learn"],
            declared: ["my-tag"],
            categoryTags: ["briefing"]
        ))
    }

    @Test("empty query is not creatable")
    func emptyQuery() {
        #expect(!TagAssignCore.canCreateTag(
            normalizedQuery: "",
            universe: ["news"], declared: [], categoryTags: []
        ))
    }

    @Test("a tag already in the universe is not creatable")
    func alreadyInUniverse() {
        #expect(!TagAssignCore.canCreateTag(
            normalizedQuery: "news",
            universe: ["news", "learn"], declared: [], categoryTags: []
        ))
    }

    @Test("an already-declared tag is not creatable")
    func alreadyDeclared() {
        #expect(!TagAssignCore.canCreateTag(
            normalizedQuery: "my-tag",
            universe: ["news"], declared: ["my-tag"], categoryTags: []
        ))
    }

    @Test("a category backing tag is not creatable as a plain tag")
    func collidesWithCategory() {
        #expect(!TagAssignCore.canCreateTag(
            normalizedQuery: "briefing",
            universe: ["news"], declared: [], categoryTags: ["briefing"]
        ))
    }
}

// MARK: - Create-category eligibility (assign window can declare new categories)

@Suite("TagAssignCore.canCreateCategory", .serialized)
struct CanCreateCategoryTests {

    @Test("a fresh name not in use is creatable as a category")
    func freshName() {
        #expect(TagAssignCore.canCreateCategory(
            normalizedQuery: "physics",
            existingTags: ["news", "learn"],
            categoryTokens: ["briefing", "series-a"]
        ))
    }

    @Test("empty query is not creatable")
    func emptyQuery() {
        #expect(!TagAssignCore.canCreateCategory(
            normalizedQuery: "",
            existingTags: ["news"], categoryTokens: []
        ))
    }

    @Test("a name colliding with an existing category token is not creatable")
    func collidesWithCategory() {
        // categoryTokens folds id + backing tag + normalized name.
        #expect(!TagAssignCore.canCreateCategory(
            normalizedQuery: "series-a",
            existingTags: ["news"], categoryTokens: ["series-a"]
        ))
    }

    @Test("a name colliding with an existing tag is not creatable")
    func collidesWithTag() {
        #expect(!TagAssignCore.canCreateCategory(
            normalizedQuery: "news",
            existingTags: ["news", "learn"], categoryTokens: []
        ))
    }
}

// MARK: - SAY-03: renameCategory guards

@Suite("CategoryStore.renameCategory", .serialized)
@MainActor
struct RenameCategoryTests {

    private func freshDefaults() -> UserDefaults { TestSupport.freshDefaults("tests.rename") }

    @Test("rename a user category succeeds and persists the new name")
    func renameSucceeds() {
        let store = CategoryStore(defaults: freshDefaults())
        _ = store.addCategory(name: "My Topic")
        let ok = store.renameCategory(id: "my-topic", newName: "Renamed Topic")
        #expect(ok == true)
        let cat = store.categories.first { $0.id == "my-topic" }
        #expect(cat?.name == "Renamed Topic")
        // Tag/id unchanged
        #expect(cat?.tag == "my-topic")
        #expect(cat?.id == "my-topic")
    }

    @Test("rename with empty string is rejected")
    func rejectEmpty() {
        let store = CategoryStore(defaults: freshDefaults())
        _ = store.addCategory(name: "My Topic")
        let ok = store.renameCategory(id: "my-topic", newName: "   ")
        #expect(ok == false)
        let cat = store.categories.first { $0.id == "my-topic" }
        #expect(cat?.name == "My Topic")  // unchanged
    }

    @Test("rename a built-in is rejected")
    func rejectBuiltin() {
        let store = CategoryStore(defaults: freshDefaults())
        let ok = store.renameCategory(id: "history", newName: "All Things")
        #expect(ok == false)
        let cat = store.categories.first { $0.id == "history" }
        #expect(cat?.name == "History")  // unchanged
    }

    @Test("rename to a reserved token is rejected")
    func rejectReservedToken() {
        let store = CategoryStore(defaults: freshDefaults())
        _ = store.addCategory(name: "My Topic")
        // "history" is a reserved token
        let ok = store.renameCategory(id: "my-topic", newName: "History")
        #expect(ok == false)
    }

    @Test("rename to a non-reserved name normalizes fine but leaves id unchanged")
    func renameIdUnchanged() {
        let defaults = freshDefaults()
        let store = CategoryStore(defaults: defaults)
        _ = store.addCategory(name: "My Topic")
        _ = store.renameCategory(id: "my-topic", newName: "Series A New")
        let cat = store.categories.first { $0.id == "my-topic" }
        #expect(cat?.name == "Series A New")
        #expect(cat?.id == "my-topic")  // id never changes

        // Persists across reopen
        let reopened = CategoryStore(defaults: defaults)
        let reopenedCat = reopened.categories.first { $0.id == "my-topic" }
        #expect(reopenedCat?.name == "Series A New")
    }

    @Test("rename nonexistent id returns false")
    func renameNonexistent() {
        let store = CategoryStore(defaults: freshDefaults())
        let ok = store.renameCategory(id: "does-not-exist", newName: "Whatever")
        #expect(ok == false)
    }
}

// MARK: - SAY-03: TagColorStore round-trip

@Suite("TagColorStore", .serialized)
@MainActor
struct TagColorStoreTests {

    private func freshDefaults() -> UserDefaults { TestSupport.freshDefaults("tests.colors") }

    @Test("default (no override) returns Tokens.tagColor")
    func defaultColor() {
        let store = TagColorStore(defaults: freshDefaults())
        let auto = Tokens.tagColor("news")
        #expect(store.color(for: "news") == auto)
        #expect(store.customHex(for: "news") == nil)
    }

    @Test("set + get a custom hex color")
    func setAndGet() {
        let store = TagColorStore(defaults: freshDefaults())
        store.setColor(for: "news", hex: "ff8800")
        #expect(store.customHex(for: "news") == "ff8800")
        #expect(store.color(for: "news") == Color(hex: "ff8800"))
    }

    @Test("a #-prefixed / uppercase hex is normalized")
    func normalizesInput() {
        let store = TagColorStore(defaults: freshDefaults())
        store.setColor(for: "news", hex: "#AABBCC")
        #expect(store.customHex(for: "news") == "aabbcc")
    }

    @Test("color persists across a store reopen")
    func persistsAcrossReopen() {
        let defaults = freshDefaults()
        let store = TagColorStore(defaults: defaults)
        store.setColor(for: "news", hex: "12ab34")

        let reopened = TagColorStore(defaults: defaults)
        #expect(reopened.customHex(for: "news") == "12ab34")
        #expect(reopened.color(for: "news") == Color(hex: "12ab34"))
    }

    @Test("clearColor removes the override and reverts to auto")
    func clearReverts() {
        let store = TagColorStore(defaults: freshDefaults())
        store.setColor(for: "news", hex: "445566")
        store.clearColor(for: "news")
        #expect(store.customHex(for: "news") == nil)
        #expect(store.color(for: "news") == Tokens.tagColor("news"))
    }

    @Test("clearColor persists across reopen")
    func clearPersists() {
        let defaults = freshDefaults()
        let store = TagColorStore(defaults: defaults)
        store.setColor(for: "news", hex: "778899")
        store.clearColor(for: "news")

        let reopened = TagColorStore(defaults: defaults)
        #expect(reopened.customHex(for: "news") == nil)
    }

    @Test("a malformed hex is rejected")
    func malformedIgnored() {
        let store = TagColorStore(defaults: freshDefaults())
        store.setColor(for: "news", hex: "nothex")
        store.setColor(for: "learn", hex: "12345")   // wrong length
        #expect(store.customHex(for: "news") == nil)
        #expect(store.customHex(for: "learn") == nil)
    }

    @Test("multiple tags have independent colors")
    func independentTags() {
        let store = TagColorStore(defaults: freshDefaults())
        store.setColor(for: "news", hex: "010203")
        store.setColor(for: "learn", hex: "0a0b0c")
        #expect(store.customHex(for: "news") == "010203")
        #expect(store.customHex(for: "learn") == "0a0b0c")
        #expect(store.customHex(for: "other") == nil)
    }
}

@MainActor
@Suite("Sidebar tag delete")
struct SidebarTagDeleteTests {
    @Test("the confirmation names the tag and how many renders lose it")
    func title() {
        #expect(Sidebar.deleteTagTitle(tag: "news", count: 3) == "Delete #news from 3 renders?")
        #expect(Sidebar.deleteTagTitle(tag: "news", count: 1) == "Delete #news from 1 render?")
        #expect(Sidebar.deleteTagTitle(tag: "news", count: 0) == "Delete #news? No render carries it.")
    }
}
