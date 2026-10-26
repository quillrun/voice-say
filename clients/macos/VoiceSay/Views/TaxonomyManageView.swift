// TaxonomyManageView — taxonomy manage window.
//
// Two sections:
//   CATEGORIES — rename display name (id/tag unchanged; free, no entry touches).
//     Built-in views (History/New/Rendering/Says) are locked — shown read-only.
//   TAGS — per-tag color (system color picker, app-side TagColorStore).
//     Tag RENAME is daemon-gated (bulk endpoint). Shown read-only with a
//     "rename arrives with the taxonomy migration" callout rather than a broken
//     inline edit. Omitted from the main flow; note at section footer.
//
// Everything commits IMMEDIATELY — this window edits the vocabulary itself
// (category + tag TYPES), so there is no Save button: renames commit on submit,
// colors on pick, add/delete on click. The per-card Tags & Category editor is
// the separate surface for editing ONE entry's assignments.

import SwiftUI

// MARK: - View

struct TaxonomyManageView: View {
    @Environment(CategoryStore.self) var categories
    @Environment(DeclaredTagsStore.self) var declaredTags
    @Environment(HistoryStore.self) var store
    @Environment(TagColorStore.self) var tagColors
    @Environment(UIRouter.self) var router

    @State private var editedNames: [String: String] = [:]      // id → in-progress rename text (commits on submit)
    @State private var newCategoryName: String = ""             // create-category field
    @State private var newTagName: String = ""                  // create-tag field
    /// Uniform height for every manage-list row. A TextField's ideal height is
    /// taller than a Text's, so without a fixed height the rename/add rows stand
    /// taller than the built-in rows. A fixed frame height also pins the row
    /// against the LazyVStack-in-ScrollView vertical-stretch (no .fixedSize needed).
    private let rowHeight: CGFloat = 32

    /// User-created tag-backed categories (excludes built-in views).
    private var userCategories: [Category] {
        categories.categories.filter { $0.tag != nil }
    }

    /// Built-in views (shown read-only).
    private var builtinCategories: [Category] {
        CategoryStore.builtins
    }

    /// All PURE tags (for the color section) — every category-backing tag
    /// subtracted, so a tag-backed category never leaks in as a plain tag
    /// (mirrors the per-card editor).
    private var allTags: [String] {
        TagAssignCore.tagListExcludingCategories(
            universe: store.tagUniverse.map { $0.0 },
            declared: declaredTags.declared,
            categoryTags: Set(categories.categories.compactMap { $0.tag })
        )
    }

    var body: some View {
        TaxonomyDialog(icon: "slider.horizontal.3", title: "Manage taxonomy",
                       subtitle: "add · rename categories · set tag colors",
                       width: 500, maxBodyHeight: 440, onClose: close) {
            categorySection
            Divider().background(Tokens.border)
                .padding(.vertical, Spacing.xs)
            colorSection
        } footer: {
            footer
        }
    }

    // MARK: - Category rename section

    @ViewBuilder
    private var categorySection: some View {
        TaxonomySectionLabel(label: "CATEGORIES", count: userCategories.count + builtinCategories.count)

        // Create a new tag-backed category (immediate — vocabulary is the
        // CategoryStore's concern, so it commits now rather than on Save).
        addCategoryRow

        // User-created tag-backed categories — renameable.
        if userCategories.isEmpty {
            TaxonomyEmptyHint("no user categories")
        } else {
            ForEach(userCategories) { cat in
                categoryRenameRow(cat)
            }
        }

        // Built-in views — locked.
        ForEach(builtinCategories) { cat in
            builtinRow(cat)
        }
    }

    private var trimmedNewCategory: String {
        newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the typed name is a creatable category: not empty, not an
    /// existing tag, not an existing category, and not a reserved/retired
    /// built-in token. Mirrors the per-render window so both surfaces agree and
    /// the "add" button reflects what CategoryStore.addCategory will accept.
    private var canAddCategory: Bool {
        let existingTags = Set(store.tagUniverse.map { $0.0 } + declaredTags.declared)
        let tokens = Set(categories.categories.flatMap { cat -> [String] in
            var t = [cat.id, CategoryStore.normalizedTag(cat.name)]
            if let tag = cat.tag { t.append(tag) }
            return t
        }).union(CategoryStore.builtinReservedTokens)
        return TagAssignCore.canCreateCategory(
            normalizedQuery: CategoryStore.normalizedTag(trimmedNewCategory),
            existingTags: existingTags,
            categoryTokens: tokens
        )
    }

    private var addCategoryRow: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.add)
                .frame(width: 16)
            TextField("new category…", text: $newCategoryName)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Tokens.text)
                .onSubmit { addCategory() }
            // When the name collides with an existing tag/category or a reserved
            // token, hint why the button is disabled.
            if !trimmedNewCategory.isEmpty && !canAddCategory {
                Text("exists")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.ultraDim)
            }
            Button(action: addCategory) {
                Text("add")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(canAddCategory ? Tokens.add : Tokens.ultraDim)
            }
            .buttonStyle(.plain)
            .disabled(!canAddCategory)
            .help("Create category")
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: rowHeight)
        .background(Tokens.add.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Tokens.add.opacity(0.4),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    private func addCategory() {
        let name = trimmedNewCategory
        guard canAddCategory else { return }
        // Immediate — CategoryStore is the vocabulary SSOT.
        _ = categories.addCategory(name: name)
        newCategoryName = ""
    }

    /// Delete a category from the registry. The backing tag stays on any entries
    /// that carry it (only the named bucket goes — same contract as
    /// CategoryStore.removeCategory). Drops any in-progress rename draft too.
    private func removeCategory(_ cat: Category) {
        if let t = cat.tag {
            store.clearTagFilterIfActive(t)
            store.clearCategoryTagIfActive(t)   // drop a dangling sidebar category filter
        }
        categories.removeCategory(cat.id)
        editedNames.removeValue(forKey: cat.id)
    }

    /// Delete a tag TYPE everywhere — strips it from every entry, the declared
    /// vocabulary, and any color override.
    private func removeTagType(_ tag: String) {
        store.clearTagFilterIfActive(tag)
        store.deleteTagEverywhere(tag)
        declaredTags.remove(tag)
        tagColors.clearColor(for: tag)
    }

    private var trimmedNewTag: String {
        newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the typed name is a creatable tag type: not empty, not already a
    /// tag, and not colliding with a category token. Mirrors the per-render
    /// window's create-tag eligibility.
    private var canAddTag: Bool {
        let nq = TagText.sanitized(trimmedNewTag)
        guard !nq.isEmpty else { return false }
        let existingTags = Set(store.tagUniverse.map { $0.0 } + declaredTags.declared)
        if existingTags.contains(nq) { return false }
        let catTokens = Set(categories.categories.flatMap { cat -> [String] in
            var t = [cat.id, CategoryStore.normalizedTag(cat.name)]
            if let tag = cat.tag { t.append(tag) }
            return t
        }).union(CategoryStore.builtinReservedTokens)
        return !catTokens.contains(nq)
    }

    private var addTagRow: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "plus")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.accent)
                .frame(width: 16)
            TextField("new tag…", text: $newTagName)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Tokens.text)
                .onSubmit { addTag() }
            if !trimmedNewTag.isEmpty && !canAddTag {
                Text("exists")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.ultraDim)
            }
            Button(action: addTag) {
                Text("add")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(canAddTag ? Tokens.accent : Tokens.ultraDim)
            }
            .buttonStyle(.plain)
            .disabled(!canAddTag)
            .help("Create tag")
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: rowHeight)
        .background(Tokens.accent.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Tokens.accent.opacity(0.4),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    /// Declare a brand-new tag type (immediate). It becomes visible in the list
    /// and everywhere tags are offered, even before any entry uses it.
    private func addTag() {
        guard canAddTag else { return }
        _ = declaredTags.add(trimmedNewTag)
        newTagName = ""
    }

    private func categoryRenameRow(_ cat: Category) -> some View {
        let binding = Binding<String>(
            get: { editedNames[cat.id] ?? cat.name },
            set: { editedNames[cat.id] = $0 }
        )
        let isDirty = (editedNames[cat.id] ?? cat.name) != cat.name

        return HStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(isDirty ? Tokens.accent : Tokens.muted)
                    .frame(width: 16)
                TextField("name", text: binding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Tokens.text)
                    .onSubmit { commitRename(cat) }
                if let tag = cat.tag {
                    Text("#\(tag)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.ultraDim)
                        .layoutPriority(-1)
                }
                Spacer()
                if isDirty {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.accent.opacity(0.8))
                }
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: rowHeight)
            .background(isDirty ? Tokens.accent.opacity(0.06) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm)
                        .stroke(isDirty ? Tokens.accent.opacity(0.3) : Tokens.borderStrong))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            // Delete the category (the backing tag stays on entries that carry it).
            ArmedDeleteControl(onDelete: { removeCategory(cat) },
                                           help: cat.tag.map { "Delete category \(cat.name) — its episodes keep #\($0)" }
                                               ?? "Delete category \(cat.name)",
                                           confirmLabel: "Delete \(cat.name)")
        }
        .padding(.trailing, Spacing.md)   // align the trash with tagColorRow's
    }

    private func builtinRow(_ cat: Category) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "lock")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.ultraDim)
                .frame(width: 16)
            Text(cat.name)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Tokens.dim)
            Spacer()
            Text("built-in")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.ultraDim)
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: rowHeight)
    }

    // MARK: - Tag color section

    @ViewBuilder
    private var colorSection: some View {
        TaxonomySectionLabel(label: "TAGS", count: allTags.count)
        Text("add / delete · set color · rename arrives with the taxonomy migration")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Tokens.ultraDim)
            .padding(.bottom, Spacing.xs)

        addTagRow

        if allTags.isEmpty {
            TaxonomyEmptyHint("no tags yet")
        } else {
            ForEach(allTags, id: \.self) { tag in
                tagColorRow(tag)
            }
        }
    }

    private func tagColorRow(_ tag: String) -> some View {
        // Draft hex for this tag: the edited value if touched, else the saved
        // one. The `?? customHex` flattens [String: String?] (.some(nil) = a
        // queued reset) down to a plain String? for display.
        let draftHex: String? = tagColors.customHex(for: tag)
        let resolvedColor: Color = draftHex.map { Color(hex: $0, fallback: Tokens.tagColor(tag)) }
            ?? Tokens.tagColor(tag)
        let isOverride = draftHex != nil

        // ColorPicker needs a non-optional Color binding; the picked color is
        // written back to the draft as hex (sRGB). Opens the macOS color window.
        let binding = Binding<Color>(
            get: { resolvedColor },
            set: { picked in
                // Ignore no-op fires (the picker re-emits the current color on
                // open/close). If the pick equals the tag's AUTO hash, clear the
                // override rather than baking the auto color in. Commits
                // immediately (no Save).
                guard let hex = picked.hexRGB, hex != draftHex else { return }
                if hex == Tokens.tagColor(tag).hexRGB {
                    tagColors.clearColor(for: tag)
                } else {
                    tagColors.setColor(for: tag, hex: hex)
                }
            }
        )

        return HStack(spacing: Spacing.sm) {
            Circle()
                .fill(resolvedColor)
                .frame(width: 9, height: 9)
            Text("#\(tag)")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(resolvedColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if isOverride {
                Button { tagColors.clearColor(for: tag) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.muted)
                }
                .buttonStyle(.plain)
                .help("Reset to auto color")
            }
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28)
            // Delete the tag TYPE everywhere (all entries + vocabulary).
            TagDeleteControl(tag: tag, usage: { store.tagUniverse.first { $0.0 == tag }?.1 ?? 0 },
                             onDelete: { removeTagType(tag) })
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: rowHeight)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            let catCount = userCategories.count
            let tagCount = allTags.count
            Text("\(catCount) categor\(catCount == 1 ? "y" : "ies")  ·  \(tagCount) tag\(tagCount == 1 ? "" : "s")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.muted)
            Spacer()
            Text("changes apply immediately")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.ultraDim)
        }
    }

    // MARK: - Actions

    /// Commit a category rename immediately (no Save button). Empty or
    /// unchanged input just drops the draft so the field shows the live name.
    private func commitRename(_ cat: Category) {
        let trimmed = (editedNames[cat.id] ?? cat.name).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != cat.name {
            _ = categories.renameCategory(id: cat.id, newName: trimmed)
        }
        editedNames.removeValue(forKey: cat.id)
    }

    private func close() {
        router.closeTaxonomyManager()
    }
}
