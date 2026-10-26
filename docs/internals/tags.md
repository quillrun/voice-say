# Tags

> The open tag vocabulary: how tags are normalized, where they are stored, and what `GET /tags` returns.

## An open vocabulary

voice-say uses an **open tag vocabulary**. Any tag is accepted from any render surface (`voice-say render`, `voice-say set`, macOS app). New tags come into existence simply by being used — there is no approved list to consult first and no proposal queue.

The vocabulary is controlled by the `allowed_tags` config key:

- `allowed_tags = []` (the committed default) — **open**: any normalized tag is accepted.
- `allowed_tags = ["summary", "briefing"]` — **closed**: only the listed tags are accepted; unknown tags are rejected at `/render` with HTTP 400.

The default shipped configuration is open (`[]`). If you want a curated, closed vocabulary for your deployment, populate `allowed_tags` in your local config overlay.

## Normalization

Every tag is normalized before it is stored or compared:

1. **trim** surrounding whitespace,
2. **lowercase**,
3. **spaces → hyphens**.

So `"Daily Notes"`, `"daily notes"`, and `"daily-notes"` all collapse to the single canonical form `daily-notes`. Normalization is applied at `/render` and at overlay tag edits, so validation stays in lockstep.

## `GET /tags`

`GET /tags` returns the distinct normalized tags **currently in use** across render history (overlay edits take precedence over the original render tags for an entry):

```json
{ "tags": ["briefing", "draft", "daily-notes"] }
```

The list grows automatically as new tags are used — no config change required.

## Two enforcement points

### 1. `/render` validates tags

When a render request carries tags, each is normalized. In open-vocabulary mode (the default), any non-empty normalized tag is accepted. In closed mode (`allowed_tags` non-empty), a tag not in the vocabulary fails the request with **HTTP 400**, and the error body includes the allowed list. The render does not proceed — no partial artefacts.

### 2. Overlay tag edits normalize on write

Overlay tag edits (`POST /overlays/{ts}` with a `tags` field) normalize tags the same way. In open mode all tags pass; in closed mode any newly added unknown tag fails the edit.

## Mechanisms that are *not* tags

Two pieces of per-entry state look tag-like but are deliberately modeled as separate fields:

- **`star`** — an overlay boolean (`starred`). A favourite flag, not a tag.
- **`completed`** — a playback progress field (`progress.completed`, set when a render is played through to the end). It is **not** a classification you supply or a stored tag on the daemon. Note, however, that the macOS client *surfaces* it as a virtual tag — see [System auto-applied tags](#system-auto-applied-tags) below.

Keeping these as mechanisms rather than reserved tag strings keeps the tag vocabulary purely descriptive and avoids collisions between user classification and system bookkeeping.

## System auto-applied tags

Three tags are applied automatically by the system rather than supplied by a user. None can be hand-edited away; each is re-derived from the mechanism that owns it.

- **`mock`** — the daemon appends `mock` to a render's tags whenever it is created with `mock=true`, so mock renders are trivially filtered and purged. A real, **server-side stored** tag (it lives in the `renders` row and appears in `GET /tags`).
- **`draft`** — the daemon appends `draft` when a streaming render is stopped early and saved as a resumable save-and-stop draft, so it lands in the Drafts category. Also **server-side stored**; it is dropped from the continuation when an episode is resumed to completion.
- **`completed`** — a **client-only virtual** tag. The macOS client derives it from the daemon's `progress.completed` field: once a render has been *played to the end*, `tagsFor()` appends `completed` (matching its `progress.completed`, i.e. playback completion — **not** render completion, which is `isComplete`). It is undeletable — guarded in `removeTag()` / `deleteTagEverywhere()` and re-appended after the removed-tag subtraction, so deleting it has no effect. Because it is never written to the store, it does **not** appear in the daemon's `GET /tags` response; it shows only in the client's local tag list and filters.

## Where tags appear

- **Render request** (`tags: [...]`) — validated (and normalized) at `/render`.
- **`renders` table** (`tags: [...]`) in the `voice.db` SQLite store — the user-supplied tags only (see [data-model.md](data-model.md)).
- **Overlay** (`tags: [...]`) — the effective, editable tag set; an overlay with `tags: []` means the user cleared them.
- **`GET /tags`** — the distinct normalized tags currently in use across history (overlay edits take precedence over the original render tags).
