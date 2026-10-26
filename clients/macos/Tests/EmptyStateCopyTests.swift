// Swift Testing coverage for EmptyState.copy: the empty-list text names the
// view that is empty rather than claiming the library is.

import Testing
@testable import VoiceSay

@Suite("Empty state copy")
struct EmptyStateCopyTests {
    @Test("an empty New inbox over a full library says nothing is new")
    func newInbox() {
        let c = EmptyState.copy(query: "", inNew: true, starred: false, libraryEmpty: false)
        #expect(c.title == "Nothing new")
    }

    @Test("only an empty library says no renders yet")
    func emptyLibrary() {
        let empty = EmptyState.copy(query: "", inNew: true, starred: false, libraryEmpty: true)
        #expect(empty.title == "No renders yet")
        #expect(empty.detail == "Press ⌘N to render your first text.")
        #expect(EmptyState.copy(query: "", inNew: false, starred: false, libraryEmpty: false).title != "No renders yet")
    }

    @Test("a search wins over the collection")
    func search() {
        let c = EmptyState.copy(query: "kiwi", inNew: true, starred: true, libraryEmpty: false)
        #expect(c.title == "No episodes match \"kiwi\"")
    }

    @Test("starred view")
    func starredView() {
        #expect(EmptyState.copy(query: "", inNew: false, starred: true, libraryEmpty: false).title == "No starred renders")
    }
}
