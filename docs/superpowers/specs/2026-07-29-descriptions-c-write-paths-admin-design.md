# Descriptions (c) — Write Paths & Admin Panel — Design

Increment (c) of the descriptions subsystem. Parent spec:
`docs/superpowers/specs/2026-07-27-descriptions-subsystem-design.md`.

Increments (a), (b1) and (b2) are merged (PRs #180, #181, #182). The `Description` table holds 198,016
rows in development and 0 in production. Nothing reads `Description` yet — that is increment (d).

## Goal

Make `Description` the thing that gets **written**, so the eleven `description` columns can stop being
written at all. Two halves:

1. The four importer/AI write sites stop clobbering `parent.description` and write their own source's row.
2. An admin panel to view, create, edit, delete and select descriptions — replacing the plain textarea
   that is being removed from nine forms.

## Scope

**In:**

- Rewire 4 write sites (2 music AI tasks, 2 IGDB providers).
- `Describable#assign_description` + `autosave: true` on the association.
- `Admin::DescriptionsController` — `index`, `create`, `update`, `destroy`, `set_preferred`.
- Nested panel on the 9 describables that have admin pages.
- `Admin::DomainRouting` entry for `Games::Series`.
- Remove the description field from 9 `_form` partials **and** `:description` from 9 controllers'
  strong params.
- Tests + Playwright E2E.

**Out:**

- **Bulk set-preferred-by-list.** Owner's call, 2026-07-29. It belongs on List admin pages, not on a
  describable's show page, and needs its own routes, an affected-count preview and a cross-record
  transaction. It is the operation with proven demand (the legacy site's "flip every book on this list
  to Goodreads" button), so it is deferred, not dropped.
- **A `deprecated` rank control.** b2 sets no deprecated rows and nothing reads the value yet, so a
  control would be inert. Additive later.
- **Public read views** — increment (d).
- **`Movies::Movie` / `Movies::Person`.** No movies admin exists and both tables are empty.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| C1 | `has_many :descriptions` gains `autosave: true` | Rails autosaves *new* children on parent save but **not modified existing ones**. The IGDB providers assign in memory and `ImporterBase#run_providers_with_saving` calls `item.save!`, so without this a **re-import** of a game that already has an `:igdb` row would assign the new summary and silently not persist it. `Identifier` dodges this only because both its attributes are lookup keys, so a found record is never dirty; `content` is not a lookup key. **The delta cuts both ways:** without `autosave`, Rails validates and saves only *new* children in the collection; with it, *changed persisted* children are validated and saved too. So an invalid changed child can now block a parent's save where previously it would have been silently ignored — which is the correct trade (silent data loss is worse than a loud failure), but it is a new failure path and gets its own test. Escape hatch if it ever misbehaves: `row.save! if persisted?` inside the helper instead, with no app-wide change. |
| C2 | One `Describable#assign_description` helper; callers persist | The two write paths genuinely differ — the AI tasks' parent is always persisted, the IGDB providers' may be a brand-new record that cannot be saved independently. A helper that only *assigns* serves both, and puts the lookup rule and D5's never-write-`rank` invariant in one place instead of four. |
| C2a | The helper looks the row up with `detect` over the association, **never `find_or_initialize_by`** | Verified empirically on PG 17 / Rails 8.1, and this is the one that would have shipped a silent bug. `find_or_initialize_by` on a *persisted* parent issues a query and returns a **detached instance that is not in the association's target**; `autosave` only iterates the target, so the parent save is a silent no-op and the content never changes — precisely the failure C1 exists to prevent. `detect` returns the target instance (or `build` puts a new one there), so autosave sees it. Costs one association load; entities carry 1–4 rows (D8), and `primary_description` already operates on the loaded collection. Also removes a second hazard: on a *new* parent, `find_or_initialize_by`'s null-scope query cannot see an already-built in-memory row, so a repeat call would build a duplicate and the natural-key index would reject the save. `detect` finds it. |
| C3 | Admin `create` offers a full source picker plus `source_url` and `license` | Owner's call. Restricting humans to `:manual` sounds safer but is not: an admin pasting Wikipedia text would be recorded as `:manual`, which is wrong provenance (D10) **and** an unattributed CC BY-SA use, since increment (d)'s `AttributionComponent` keys off `license` + `source_url`. Mislabelling is possible but visible; silent misattribution is neither. |
| C4 | `rank` appears in no form; only `set_preferred` changes it | D5. A form that could set `preferred` directly would skip the demotion and hit `index_descriptions_one_preferred_per_key`, raising `PG::UniqueViolation`. |
| C5 | `kind` and `locale` are hardcoded `:summary` / `"en"` on create | Every row in the app is that today. D2/D3 justify the *columns* existing for a future the UI does not need yet. Rows at other values still list and delete; they just cannot be created here. |
| C6 | `Games::Series` gets an `Admin::DomainRouting` entry | It has full admin CRUD but is absent from the registry, so `path_for` returns nil and it cannot host a nested panel. Adding it is a config entry, which is how that registry is designed to grow. It also closes a read-path gap: `admin/games/series/_table.html.erb:29` reads `series.description` and would break at increment (e). |
| C7 | Stripping the field from the 9 forms is not optional | Once (d) reads `primary_description`, a form writing the column is a control that silently does nothing; at (e) it references a dropped column and errors. |

## Write path

```ruby
# app/models/concerns/describable.rb
has_many :descriptions, -> { order(:id) }, as: :describable, dependent: :destroy, autosave: true

def assign_description(source:, content:, **attrs)
  return nil if content.blank?

  row = descriptions.detect { |d| d.kind == "summary" && d.locale == "en" && d.source == source.to_s } ||
    descriptions.build(kind: :summary, locale: "en", source: source)
  row.assign_attributes(content: content, retrieved_at: Time.current, **attrs)
  row
end
```

Never assigns `rank` (D5). Returns `nil` on blank content, so `descriptions_content_not_blank` can
never abort a caller's save. `detect`, not `find_or_initialize_by` — see C2a; the latter returns a
detached instance and silently loses the write.

`d.source == source.to_s` because the enum reader returns a `String` while callers pass a `Symbol`.

### Verified behaviour (PG 17 / Rails 8.1, 2026-07-30)

| Case | Result |
|---|---|
| `find_or_initialize_by` + `parent.save!`, persisted parent, existing row | **Silently does not update** — instance is not in the association target |
| ...same, association pre-loaded | **Still does not update** — `find_by` issues a fresh query either way |
| `detect` + `parent.save!`, persisted parent, existing row | Updates correctly |
| `detect` + `parent.save!` **without** `autosave: true` | **Does not update** — so C1's association change is genuinely required |
| `build` on a new parent, no `autosave` | Saves (new children always do), so `autosave` matters only for the changed-existing case |
| `autosave: true` with an invalid changed child | Blocks the parent save with `RecordInvalid` — the new failure path named in C1 |

| Site | Parent state | How it persists |
|---|---|---|
| `DataImporters::Games::Game::Providers::Igdb#populate_game_data` | may be unsaved | assign only; `ImporterBase#run_providers_with_saving`'s `item.save!` cascades (C1) |
| `DataImporters::Games::Company::Providers::Igdb` | may be unsaved | same |
| `Services::Ai::Tasks::Music::AlbumDescriptionTask#process_and_persist` | always persisted | `parent.assign_description(source: :ai_generated, content: data[:description])&.save!` |
| `Services::Ai::Tasks::Music::ArtistDescriptionTask` | always persisted | same |

Both IGDB providers keep their existing `if ...present?` guard. The AI tasks keep their
`present? && !abstained` guard. Neither path writes the `description` column any more.

**The clobber bug dies here.** `parent.update!(description:)` overwrote whatever was there, so an AI
regeneration destroyed hand-written text. Writing to the `:ai_generated` row leaves a `:manual` row
untouched, and `:manual` outranks `:ai_generated` in `SourcePriority::ORDER`, so the human's text keeps
winning. Pinned by a regression test.

## Admin panel

Mirrors `Admin::ImagesController`: a single global controller, `index`/`create` nested per parent,
`update`/`destroy`/`set_preferred` global, a lazily-loaded `turbo_frame_tag "descriptions_list"`, and
`Admin::DomainScopedAuth` + `require_domain_write!`.

```ruby
# nested, per parent
resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"

# global
resources :descriptions, only: [:update, :destroy], controller: "descriptions" do
  member { post :set_preferred }
end
```

Mounted on the show page the same way images are:

```erb
<%= turbo_frame_tag "descriptions_list", loading: :lazy, src: admin_album_descriptions_path(@album) do %>
```

### `set_preferred`

Demote-then-promote inside a transaction. It **cannot** mirror `Image#unset_other_primary_images`, an
`after_save` that promotes first — under D14's partial unique index that ordering violates the
constraint mid-callback.

```ruby
Description.transaction do
  Description
    .where(describable_type: @description.describable_type, describable_id: @description.describable_id,
      kind: @description.kind, locale: @description.locale, rank: :preferred)
    .where.not(id: @description.id)
    .update_all(rank: 0) # 0 = :normal; update_all bypasses enum casting
  @description.update!(rank: :preferred)
end
```

`update_all` is deliberate: one statement, no callbacks, and no intermediate state visible to another
connection. It takes the raw integer `0` because `update_all` writes straight to SQL without the enum
cast. `where.not(id:)` makes the action idempotent — re-running it on the row that is already preferred
must not demote the row it is about to promote.

### Form fields

`content`, `source`, `source_name`, `source_url`, `license`. `source_name` is shown only when `source`
is `:other` — the model enforces the biconditional (`presence` if `source_other?`, `absence` otherwise)
and `descriptions_source_name_matches_source` enforces it in the database.

A duplicate `(describable, kind, locale, source, source_name)` is caught by the model's uniqueness
validation and surfaces as a form error, not a 500.

### Not to copy from `Admin::ImagesController`

The polymorphic association is `describable`, not `parent` (the `_able` convention), so
`params[:parent_type]` and `parent.images` have no equivalent. And per D13 this is a review-and-select
surface: `create` exists as an override, but the emphasis is view / `set_preferred` / delete.

## Parents (9)

| Domain | Models | Registry work |
|---|---|---|
| Music | `Music::Album`, `Music::Artist`, `Music::Song` | none — all in `ENTITIES` + `NESTED_PARENTS` |
| Games | `Games::Game`, `Games::Company` | none |
| Games | `Games::Series` | **add to `ENTITIES` and `NESTED_PARENTS[:games]` as `series_id`** (C6) |
| Books | `Books::Book`, `Books::Author`, `Books::Series` | none |

`Books::Edition` is in `ENTITIES` but is **not** `Describable` and gets no panel.

## Forms and strong params (9 each)

Remove the description field from `admin/{books/{books,authors,series},games/{games,companies,series},music/{albums,artists,songs}}/_form.html.erb`
and `:description` from the matching controllers' `permit` lists. Verified: all nine currently permit it.

`admin/penalties/_form` and both `ranking_configurations/_form` partials **keep** theirs — authored
config, not sourced content.

## Testing

- `Admin::DescriptionsControllerTest` — CRUD, `set_preferred`, and `require_domain_write!` denials.
- **Clobber regression:** AI regeneration writes its own row and leaves a `:manual` `preferred` row
  untouched in both content and rank.
- **`set_preferred` demotes the incumbent** rather than raising `PG::UniqueViolation`.
- **IGDB re-import persists a changed summary** — the C1 autosave gap. This is the test that fails if
  `autosave: true` is ever removed **or** if the helper's `detect` is refactored back into
  `find_or_initialize_by` (C2a). Both regressions are silent without it, so it is the single most
  load-bearing test in this increment.
- **An import still succeeds end-to-end** with the description association in play, proving `autosave`
  did not introduce a child-validation path that blocks `item.save!`.
- Updated importer and controller tests for the nine stripped forms.
- Playwright E2E: add a description, set it preferred, delete it.

Gate: `bin/rails test`, `bin/rails test:system`, `bundle exec standardrb`.

## Deploy ordering

Owner's constraint, 2026-07-29: **the production backfill runs before (c) ships.**

`data_migration:description_columns` (b1) and `data_migration:descriptions` (b2) have never run in
production. (c) is display-safe at `Description.count = 0`, since the public views still read the
columns until (d) — but stripping the field from the nine forms makes any production description that
exists only as a column **un-editable**, because the panel reads `Description` rows and there would be
none.

Two prerequisites for the b2 half of that production run, neither verified yet:

- production must be able to reach the `legacy_books` database;
- production must have `Books::Book` / `Books::Author` rows.

If the books data is not in production, `BookDescriptionMigrator` raises on the first legacy book —
`preload_context` builds the id set upfront — so it fails on batch one with zero rows written, and the
`abort` added in b2's final review stops the chain before the safety net can run. No partial state.
b1 is independent of all of this and can run regardless.

### c1 alone is not deployable

The backfill constraint above covers *existing* descriptions. c1 (the write path) also affects
*newly written* ones: after c1, a freshly imported IGDB game or company, and every AI description
regeneration, write only a `Description` row — but every public and admin view still reads the
`description` **column** until increment (d). So a game imported the day after c1 deploys would show
no description anywhere, and without c2's admin panel there would be no way to even see the text that
was written. Existing data is unaffected; this only bites records touched after c1 deploys.

c1 must therefore not reach production on its own — it needs (d), the read path, for newly-written
descriptions to be visible. c2's admin panel makes them at least inspectable sooner, but does not
substitute for (d).

## Suggested increments

1. **Write path** — `autosave: true`, `Describable#assign_description`, 4 sites rewired, clobber
   regression + IGDB re-import tests. No UI.
2. **Admin panel** — controller, routes, views, `set_preferred`, `Games::Series` registry entry, E2E.
3. **Form stripping** — 9 forms + 9 strong-param lists, updated controller tests.

Increment 3 must land with or after 2: once the field is gone, the panel is the only way to edit a
description.
