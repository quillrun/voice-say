// TaxonomyManager — sidebar taxonomy manager: the one place that changes the
// library-wide vocabulary (add, rename and delete categories; add, colour and
// delete tags). The per-episode and compose pickers only assign and create.
// A second "add / remove" tab duplicated this screen and was folded in.
//
// Thin wrapper preserving the call site (ContentView) and environment
// injection contract unchanged.

import SwiftUI

struct TaxonomyManager: View {
    var body: some View { TaxonomyManageView() }
}
