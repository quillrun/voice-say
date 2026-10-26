// TagPicker — per-render tag + category picker.
//
// Entry-bound mode (router path): routes to TagAssignEditor — the new
// diff-save assign window with single-select category and category-tag
// exclusion from the tags list.
//
// Staging mode (compose path): stays on TaxonomyEditor (compose stages tags
// before a render exists; the assign-window semantics don't apply).

import SwiftUI

struct TagPicker: View {
    // Entry-bound mode (router path): edits one render's tag membership.
    var entryID: String? = nil
    // Staging mode (compose path): edits a Set<String> binding directly.
    var staging: Binding<Set<String>>? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        if let binding = staging {
            // Compose staging path — TaxonomyEditor stages the set binding.
            TaxonomyEditor(staging: binding, onClose: onClose)
        } else {
            // Per-entry assign window.
            TagAssignEditor(entryID: entryID, onClose: onClose)
        }
    }
}
