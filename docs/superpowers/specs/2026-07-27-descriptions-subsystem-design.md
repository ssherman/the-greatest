# Descriptions Subsystem — Design

**Status:** Design approved by owner 2026-07-27. Spec pending owner review.

**Goal:** Replace the per-model `description` column with a polymorphic `Description` model that holds
many descriptions per entity — one per `(kind, locale, source)` — with per-row provenance, licence, and
an explicit "which one wins" mechanism. Backfill it from the legacy books database and from the
existing in-app columns, then drop the columns.

**Why now:** The books public UI (deferred to a follow-up spec) needs `/book/:slug` to render the
description the legacy site actually displays. It currently cannot: `Services::BooksMigration::BookTransformer`
ported only `description`, while the legacy site displays `description_to_display`, which resolves to
`ai_generated_description` for 87.5% of books. Fixing that by porting `ai_generated_description` and
`goodreads_description` as columns would import the legacy design's central flaw — source-specific
columns (`goodreads_description`) that are meaningless for music, movies, and games.

---

## Scope

**In:** the `Description` model + schema; the `Describable` concern and `Descriptions::Resolver`;
three backfills (legacy books, legacy authors, in-app columns); rewiring the four write paths;
rewiring the five public and nine admin read sites; a `Descriptions::AttributionComponent`; an
`Admin::DescriptionsController` mirroring `Admin::ImagesController`; dropping the eleven columns.

**Out (deferred, with rationale in "Follow-ups"):** `review_state`, `digital_source_type`,
`content_format`, description versioning, a `Source` table, retrieval-enabled AI description
generation, and the books public UI itself.

---

## Current state (verified 2026-07-27)

### The porting gap

`BookTransformer` line 14 is `description: attrs["description"]` — the raw column only. The legacy
`Book#description_to_display` resolves three columns through the `use_description` enum:

```ruby
case use_description
when "default"         then ai_generated_description.presence || goodreads_description.presence || description
when "use_goodreads"   then goodreads_description.presence   || ai_generated_description.presence || description
when "use_description" then description.presence             || ai_generated_description.presence || goodreads_description
end
```

`AuthorTransformer` has the same gap; the legacy author page renders
`@author.ai_description || @author.description`.

### Legacy books (126,204 rows)

| Column | Populated |
|---|---|
| `ai_generated_description` | 111,447 |
| `description` | 20,242 |
| `goodreads_description` | 8,162 |
| `description_source_name` | 19,897 |
| `description_source_url` | 19,664 |

`use_description`: `default` 124,065 · `use_goodreads` 2,137 · `use_description` 2.

**Which source actually wins today**, computed per book across all 126,204:

| Winner | Books | Share |
|---|---|---|
| `ai_generated_description` | 110,400 | 87.5% |
| `goodreads_description` | 2,026 | 1.6% |
| raw `description` | 632 | 0.5% |
| nothing | 13,146 | 10.4% |

Of the 632 where raw text wins: 461 Wikipedia, 135 no stated source, 35 OpenLibrary, 1 Google. So the
10,638 Wikipedia and 7,513 OpenLibrary descriptions are stored but almost never displayed — AI outranks
them under `default`.

`description_source_name` is dirty and needs normalising: `wikipedia` 8,593 · `Wikipedia` 2,025 ·
`WIkipedia` 13 · `"Wikipedia "` 7 · `OpenLibrary` 7,513 · `Google` 1,448 · `Publisher` 105 ·
`"Publisher "` 98 · `Amazon.com` 19 · long tail of magazines. Hosts in `description_source_url`:
`en.wikipedia.org` 10,609 · `openlibrary.org` 7,513 · `books.google.com` 1,303 · `play.google.com` 163.

### Legacy authors (58,193 rows)

| Column | Populated | Source |
|---|---|---|
| `ai_description` (**not** ported) | 38,114 | ours |
| `description` (ported) | 8,670 | ~100% Wikipedia (`wikipedia` 6,953 + `Wikipedia` 2,191) |

### In-app description columns

| Model | Populated / total | Provenance | How established |
|---|---|---|---|
| `Books::Book` | — | legacy raw `description` | already migrated; superseded by the legacy backfill |
| `Books::Author` | 8,670 / 58,214 | legacy Wikipedia | same |
| `Music::Album` | 3,649 / 4,119 | `:ai_generated` | see below |
| `Music::Artist` | 5,468 / 7,382 | `:ai_generated` | see below |
| `Games::Game` | 1,602 / 1,624 | `:igdb` | `Igdb#populate` is the only writer (`game.description = game_data["summary"]`) |
| `Games::Company` | 658 / 1,285 | `:igdb` | same |
| `Games::Series` | 5 / 15 | `:manual` | no importer writes it |
| `Music::Song` | 0 / 87,145 | — | nothing to migrate |
| `Movies::Movie`, `Movies::Person` | 0 / 0 | — | nothing to migrate |
| `Books::Series` | 0 / 18 | — | nothing to migrate |

**Music descriptions are AI, not MusicBrainz.** Three independent checks agree: the MusicBrainz
providers (`music/{album,artist,release,song}/providers/music_brainz.rb`) never assign `description` —
only `ai_description.rb` does; `ai_chats` counts (`Music::Album` 7,561, `Music::Artist` 7,378) exceed
the description counts, consistent with the task's `abstained: true` path; and the text matches
`AlbumDescriptionTask`'s system prompt ("one paragraph, no marketing language") verbatim in style.

This distinction is load-bearing. MusicBrainz **annotations** are CC BY-NC-SA 3.0, not CC0 like their
core data — had music descriptions been MusicBrainz text, they would be non-commercial and unusable on
an ad-supported site. They are ours, so they are clean.

### Write sites (4)

- `Services::Ai::Tasks::Music::AlbumDescriptionTask#process_and_persist` → `parent.update!(description:)`
- `Services::Ai::Tasks::Music::ArtistDescriptionTask#process_and_persist` → same
- `DataImporters::Games::Game::Providers::Igdb` → `game.description = game_data["summary"]`
- `DataImporters::Games::Company::Providers::Igdb` → same

**The AI tasks clobber.** `parent.update!(description:)` overwrites whatever is there, so an AI
regeneration silently destroys hand-written text. Fixing this is a side effect of the new model, and
is pinned by a regression test.

### Read sites

**Public (5):** `games/games/show`, `music/albums/show`, `music/songs/show`, `music/artists/show`,
`music/albums/lists/show` (renders a blurb per list row — the only N+1 risk).

**Admin show pages (9):** `admin/games/{games,companies,series}/show`,
`admin/music/{albums,artists,songs}/show`, `admin/books/{books,authors,series}/show`.

**Admin forms with a description field (9):** `admin/books/{authors,books,series}/_form`,
`admin/games/{companies,games,series}/_form`, `admin/music/{albums,artists,songs}/_form`.
`admin/penalties/_form` and `admin/ranking_configurations/_form` keep theirs — authored config, not
sourced content.

Description appears in **no search index**, so there is no reindex concern. There is **no PaperTrail or
`audited` gem** in the app.

---

## Prior art

Research summary; full findings and citations in the conversation record.

**No mainstream media database does row-per-source.** MusicBrainz, Open Library, TMDB, IGDB, Discogs,
and Wikidata each keep exactly one description slot (sometimes one per language) and resolve source
conflicts *at import time*. The only mature row-per-source precedent is **MARC 21 field 520** —
repeatable since the 1960s, carrying `$c` "assigning source", `$u` URI, and indicator-1 as a *kind*
discriminator (Summary / Review / Abstract / Scope and content). We are building the resolution logic
the media databases avoided; that is real work, not a `default: true` boolean.

Where systems agree, the signal is strong:

- **`kind` is a separate dimension from `source`** — universal (IGDB `summary` vs `storyline`; Open
  Library `description`/`first_sentence`/`notes`; MARC 520 indicator-1).
- **Language is first-class where multilingual, and fallback is never automatic.** TMDB returns an
  empty string rather than falling back.
- **Versioning is general-purpose and record-level**, not description-specific. MusicBrainz is the lone
  exception and its model breaks under multi-source merge — its entity-merge code concatenates two
  annotations with `"\n\n-------\n\n"` under a bot account because it cannot represent two coexisting
  descriptions.

**Selection mechanisms and their failure modes:**

| Mechanism | Who | Failure |
|---|---|---|
| Newest row wins | MusicBrainz (`ORDER BY created DESC LIMIT 1`) | any importer re-run silently takes over |
| Set only if absent | Open Library import | the worst early source wins permanently; no upgrade path |
| Per-field lock flag on the parent | Jellyfin | issues [#6601](https://github.com/jellyfin/jellyfin/issues/6601) (unenumerated field cannot be locked), [#15549](https://github.com/jellyfin/jellyfin/issues/15549) (locks lost on restart), [#15596](https://github.com/jellyfin/jellyfin/issues/15596) |
| Rank: preferred / normal / deprecated | Wikidata statements | requires editorial discipline, but expresses "known bad" without deletion |
| Source stated in prose | Discogs | unqueryable, and becomes part of the displayed text |

The Jellyfin trail is the argument against a lock flag on the parent: the editor's choice must live
**on the row it protects**, so that "importers never touch rows they did not create" is structural
rather than a rule every code path has to remember.

**Licensing** is per-row, not per-source. Wikidata descriptions are CC0 while Wikipedia extracts are
CC BY-SA 4.0 — same integration, different licence. MusicBrainz core data is CC0 but annotations are
CC BY-NC-SA 3.0. TMDB's API terms forbid caching content longer than six months, which makes
`retrieved_at` load-bearing rather than decorative.

**Wikipedia CC BY-SA imposes four obligations:** attribution (link to the source page), a licence
notice, indicating modification (truncating an extract counts), and share-alike. The legacy site stores
`description_source_name`/`_url` and never displays them. We inherit that gap and close it.

**Goodreads.** Their [Terms of Service](https://www.goodreads.com/about/terms) prohibit "any collection
and use of any book listings, descriptions, reviews or other material", and the API was retired in
December 2020. The owner's decision (D9) is to migrate the existing rows anyway, on the grounds that the
text is already published on the live site and migrating between our own databases changes no exposure.
The per-row `license` column makes the encumbered rows queryable for the first time.

---

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Polymorphic `Description` with natural key `(describable, kind, locale, source)` | Mirrors `Image` and `ExternalLink`, the two existing polymorphic child-record patterns. Explicitly **not** `(entity, locale)` — Wikidata's constraint, which forces destructive import the moment two sources supply the same language. |
| D2 | `kind` enum, default `:summary` | The one dimension every surveyed system has. One integer column now; a migration across every row later. |
| D3 | `locale` string, default `"en"` | Books span many original languages. Cheap now, expensive to add to a table with a unique index later. |
| D4 | `rank` enum `{deprecated: -1, normal: 0, preferred: 1}` — not a `primary` boolean | Wikidata's model. `deprecated` lets a known-bad row stay for idempotent re-import while being permanently excluded from display; a boolean cannot express that. |
| D5 | Importers may only create/update the row matching their own `source`, and may **never** write `rank`. Only *deliberate selection operations* set `preferred` — and those are usually programmatic, not per-record clicks. | Makes the Jellyfin lock-flag failure mode structurally impossible. Replaces `pinned_at`/`pinned_by` from the research recommendation — with this invariant, `rank: :preferred` already *is* the record of the selection. **Corrected 2026-07-28:** an earlier wording said "only humans set `preferred`", which misdescribes the real workflow. On the legacy site the owner's main use of `use_description` was a **bulk button that flipped every book on a list to Goodreads**, because the books were that year's releases and the AI did not know them. The distinction that matters is not human-vs-machine but *syncing a source* (never touches `rank`) vs *choosing which source wins* (may). |
| D14 | The DB enforces at most one `preferred` row per `(describable, kind, locale)` — partial unique index `WHERE rank = 1` | D5 is otherwise only a convention, and the operations that set `preferred` are bulk writes, which is exactly where a convention breaks silently. A bulk switch that sets new `preferred` rows without clearing the old ones would leave every affected record double-flagged, with no error and no symptom — the resolver would quietly fall back to source priority, the very thing `preferred` exists to override. Added while the table was empty; after the backfill it would cost a 198k-row validation pass. Consequence: increment (c)'s `set_preferred` must demote-then-promote inside a transaction, so it cannot mirror `Image#unset_other_primary_images` (an `after_save` that promotes first). |
| D15 | `content` carries a DB check constraint `length(btrim(content)) > 0`, not just `validates :content, presence: true` | `null: false` does not stop `""`, and the backfill's `upsert_all` bypasses validations. Verified empirically: a blank-content row was accepted under `upsert_all`. A `build_rows` that tests truthiness instead of `.presence` would land empty descriptions in production *and still pass the row-count verification*. **Known gap:** single-argument `btrim` trims ASCII spaces only, so `"\t\n"` passes the DB check while being `.blank?` in Ruby. Not load-bearing — the failure mode being guarded produces `""` — but worth widening if increment (b) touches this migration anyway. |
| D6 | `license` and `source_url` per row; `retrieved_at` per row | Wikidata CC0 vs Wikipedia CC BY-SA arrive from the same integration. TMDB's 6-month cache limit needs `retrieved_at` the day we add a TMDB importer. |
| D7 | Read through `primary_description`; drop the eleven columns | Owner's call over keeping the column as a maintained cache. One representation, nothing to drift. |
| D8 | No `has_one :primary_description` — a `Descriptions::Resolver` over a loaded collection | The winner is computed, not flagged, so a `has_one` scope cannot express it. Entities carry 1–4 rows, so `includes(:descriptions)` is one extra query total. |
| D9 | Migrate Goodreads rows as a normal source with `license: :proprietary` | The text is already published on the live site; purging would be a new decision that costs 885 books their description. Whether to keep *acquiring* Goodreads text is a separate, later decision. |
| D10 | Every migrated row gets real provenance; no `:unknown` source value | Provenance was verifiable for every column (see "Current state"). Guessing would put wrong provenance on rows we could not later distinguish from correct ones. |
| D11 | The backfill marks `rank: :preferred` only where a *human* chose, not on every winner | `use_description = default` (124,065 books) is reproduced exactly by `SourcePriority::ORDER`. Only the 2,139 explicit choices become `preferred`. `use_description` becomes data rather than a rule. |
| D12 | Dropping the columns ships as its own PR, after increments a–d run in production | A bad backfill followed by a column drop is unrecoverable, and in dev the books data exists nowhere else. |
| D13 | Admin panel is a review-and-select surface, not an authoring one | Owner: admins will not manually write descriptions; generation will be AI. `create` remains for override; emphasis is on `set_preferred` and delete. |

---

## Schema

```ruby
create_table :descriptions do |t|
  t.references :describable, polymorphic: true, null: false
  t.integer  :kind,        null: false, default: 0
  t.string   :locale,      null: false, default: "en"
  t.integer  :source,      null: false
  t.string   :source_name
  t.text     :content,     null: false
  t.integer  :rank,        null: false, default: 0
  t.string   :source_url
  t.integer  :license
  t.datetime :retrieved_at
  t.timestamps
end

add_index :descriptions,
  %i[describable_type describable_id kind locale source source_name],
  unique: true, nulls_not_distinct: true,
  name: "index_descriptions_on_describable_and_key"
```

`source_name` sits **inside** the unique index so two different `:other` sources do not collide.

**`nulls_not_distinct: true` is load-bearing, not a refinement.** `source_name` is `NULL` for every
non-`:other` row, and Postgres treats `NULL`s as distinct by default — so without it the index would
happily accept two `(book, summary, en, wikipedia, NULL)` rows, defeating uniqueness for ~99.99% of the
table. Requires PostgreSQL 15+ (we run 17.4) and Rails 7.1+ (we run 8.1.3).

A CHECK constraint keeps `:other` rows attributable:

```sql
ALTER TABLE descriptions ADD CONSTRAINT descriptions_other_requires_source_name
  CHECK (source <> 9 OR source_name IS NOT NULL);
```

Two further DB-level guards, added because `upsert_all` bypasses every model validation (D14, D15):

```ruby
add_check_constraint :descriptions, "length(btrim(content)) > 0",
  name: "descriptions_content_not_blank"

add_index :descriptions, [:describable_type, :describable_id, :kind, :locale],
  unique: true, where: "rank = 1", name: "index_descriptions_one_preferred_per_key"
```

```ruby
class Description < ApplicationRecord
  belongs_to :describable, polymorphic: true

  enum :kind,    {summary: 0, long: 1, first_sentence: 2, blurb: 3}
  enum :rank,    {deprecated: -1, normal: 0, preferred: 1}
  enum :license, {cc0: 0, cc_by_sa_4: 1, proprietary: 2}, prefix: true
  enum :source,  {manual: 0, ai_generated: 1, wikipedia: 2, openlibrary: 3,
                  musicbrainz: 4, igdb: 5, publisher: 6, goodreads: 7, other: 9},
                 prefix: true

  validates :content, presence: true
  validates :locale, presence: true
  validates :source_name, presence: true, if: :source_other?
end
```

`license` is nullable; `NULL` means "not recorded", so there is no `unknown_license` member. The
`source` enum leaves 8 free for a future value without renumbering `:other`.

`source` and `license` take `prefix: true`, matching `ExternalLink` — bare `amazon?`/`cc0?` would be
ambiguous, and the prefix is what makes `source_other?` exist for the validation above. `kind` and
`rank` stay unprefixed: `summary?`, `preferred?`, `deprecated?` read naturally and collide with
nothing.

---

## Selection

```ruby
# app/lib/descriptions/source_priority.rb
module Descriptions
  module SourcePriority
    ORDER = %w[manual ai_generated goodreads wikipedia
               openlibrary publisher musicbrainz igdb other].freeze
  end
end
```

It lives in its own file because Zeitwerk keys autoloads off file names: a bare
`Descriptions::SOURCE_PRIORITY` sitting beside `Resolver` in `resolver.rb` raises `NameError` on first
reference under `eager_load: false` (development and local test runs) unless something has already
touched `Resolver`. Strings, not symbols — `description.source` returns a `String`.

`Descriptions::Resolver.call(descriptions, kind: :summary, locale: "en")` is pure and operates on an
already-loaded collection:

1. reject `deprecated`
2. reject rows not matching `kind` and `locale`
3. return the `preferred` row if one exists
4. otherwise return the `normal` row whose `source` comes first in `SourcePriority::ORDER`
5. otherwise `nil`

`ai_generated` ahead of `goodreads` ahead of the sourced-text values reproduces the legacy books
`default` behaviour exactly, and `ai_generated` ahead of `wikipedia` reproduces the legacy author page's
`ai_description || description`.

```ruby
module Describable
  extend ActiveSupport::Concern

  included do
    has_many :descriptions, as: :describable, dependent: :destroy
  end

  def primary_description(kind: :summary, locale: "en")
    Descriptions::Resolver.call(descriptions, kind: kind, locale: locale)
  end
end
```

Included into `Books::Book`, `Books::Author`, `Books::Series`, `Music::Album`, `Music::Artist`,
`Music::Song`, `Games::Game`, `Games::Company`, `Games::Series`, `Movies::Movie`, `Movies::Person`.

---

## Backfill

Three migrators. All idempotent, all `BulkUpsertMigrator` with `unique_by:` the new index, following
the pattern of PRs #159–#179.

### 1. `Services::BooksMigration::BookDescriptionMigrator`

Reads **all three legacy columns**, and **not** the current `books_books.description` — that column
already *is* the legacy raw `description` from the earlier migration, so reading it too would
double-create.

| Legacy column | `source` | `license` | Rows |
|---|---|---|---|
| `ai_generated_description` | `:ai_generated` | NULL | 111,447 |
| `goodreads_description` | `:goodreads` | `:proprietary` | 8,162 |
| `description` | normalised from `description_source_name` | per source | 20,242 |

Source-name normalisation (strip, downcase): `wikipedia` → `:wikipedia` + `:cc_by_sa_4` ·
`openlibrary` → `:openlibrary` + `:cc0` · `google`, `google books` → `:other` + `source_name: "Google Books"` ·
`publisher` → `:publisher` · everything else → `:other` + **stripped** `source_name` · blank → `:other` +
`source_name: "Unattributed"`.

`source_name` is stripped, not stored verbatim: legacy holds `"Publisher "` (98 rows, trailing space)
alongside `"Publisher"`, and since `source_name` sits inside the unique key those would become two
distinct rows and two near-duplicate source labels in the admin UI. Case is preserved — only whitespace
is trimmed.

`source_url` ← `description_source_url`. `retrieved_at` stays NULL — legacy never recorded it, and
back-dating from `updated_at` would be a fabrication. `locale: "en"`, `kind: :summary` throughout.

`rank: :preferred` only on the 2,139 books where `use_description != default` — the `:goodreads` row for
the 2,137 `use_goodreads` books, the raw-`description` row for the 2 `use_description` books. Everything
else `:normal`, resolved by `SourcePriority::ORDER`.

### 2. `Services::BooksMigration::AuthorDescriptionMigrator`

Same shape, reading legacy `authors`. `ai_description` (38,114) → `:ai_generated`; `description`
(8,670) → `:wikipedia` + `:cc_by_sa_4`, `source_url` ← `description_source_url`. No `preferred` rows —
`SourcePriority::ORDER` reproduces `ai_description || description`.

### 3. `Services::DescriptionColumnBackfill`

**Not** `Services::Descriptions::ColumnBackfill`. Inside `module Services; module Descriptions`, the
constant `Descriptions` resolves lexically to `Services::Descriptions` — itself — so
`Descriptions::SourcePriority::ORDER` and `Descriptions::Resolver` both raise `NameError`. (The model
`Description` still resolves; only the `Descriptions::` namespace is shadowed.) This is the same
landmine as `Services::BooksMigration`'s bare `Music::`. If a `Services::Descriptions` namespace is
ever wanted anyway, every reference must be written `::Descriptions::…`.

The in-app columns, all at `rank: :normal`:

| Column | `source` | Rows |
|---|---|---|
| `games_games.description` | `:igdb` | 1,602 |
| `games_companies.description` | `:igdb` | 658 |
| `music_albums.description` | `:ai_generated` | 3,649 |
| `music_artists.description` | `:ai_generated` | 5,468 |
| `games_series.description` | `:manual` | 5 |

Plus a safety net: any `Books::Book` or `Books::Author` with a non-empty `description` and no row after
the legacy backfill — the ~50 books and ~21 authors created in-app rather than migrated — gets a
`:manual` row.

`rank: :normal`, not `:preferred` — corrected 2026-07-28. Every entity this backfill touches receives
exactly **one** row (games get only `:igdb`, music only `:ai_generated`, `games_series` only `:manual`,
and the safety net fires only where no row exists). With one row the two ranks display identically,
so `preferred` buys nothing while manufacturing ~11,382 records of a choice nobody made — contradicting
D5. The cost lands later: an editor writes a `:manual` description for an album and it does not display,
because a backfill marked the AI row preferred. Under D14's partial unique index this is also the shape
that would collide first.

### Verified safe for the backfill (probed on PG 17, 2026-07-28)

- `upsert_all(unique_by: :index_descriptions_on_describable_and_key)` **does** infer the arbiter against
  a `NULLS NOT DISTINCT` index — rows with a NULL `source_name` de-duplicate correctly.
- `upsert_all` serialises enum **symbols** through the model's attribute types, so `build_rows` can emit
  `{source: :ai_generated, rank: :normal}` with no manual integer mapping.
- The `descriptions_other_requires_source_name` check constraint **is** enforced under `upsert_all`
  (raises `ActiveRecord::CheckViolation`).
- `unique_by:` addressed by index name matches the existing `BulkUpsertMigrator` contract, so the
  migrators need no base-class change.

### Landmine for the backfill

Two rows sharing the conflict key **in the same `upsert_all` batch** raise
`PG::CardinalityViolation: ON CONFLICT DO UPDATE command cannot affect row a second time`, killing the
whole batch — the same failure `ListPenaltyMigrator` needed its `@seen` set for. `build_rows` looks safe
by construction here (each legacy book yields at most one row per source, and no normalisation target
collides with `:ai_generated` or `:goodreads`), but that safety is incidental: if `description_source_name`
normalisation ever maps onto a source another column already claims, the batch dies. Either dedup per
batch or state in a comment why one is unnecessary.

### Verification

Exact counts, then a no-op second run:

| Group | Rows |
|---|---|
| books | 139,851 |
| authors | 46,784 |
| games | 2,265 |
| music | 9,117 |
| **total** | **198,017** |

Plus a spot-check that `Books::Book#primary_description&.content` equals legacy
`Book#description_to_display` for a sample spanning all four `use_description`/winner combinations.

---

## Cutover

### Write path

```ruby
# Services::Ai::Tasks::Music::{Album,Artist}DescriptionTask#process_and_persist
- parent.update!(description: data[:description])
+ parent.descriptions
+       .find_or_initialize_by(kind: :summary, locale: "en", source: :ai_generated)
+       .update!(content: data[:description], retrieved_at: Time.current)
```

`DataImporters::Games::{Game,Company}::Providers::Igdb` do the same against `source: :igdb`. Note these
providers assign attributes to a **not-yet-persisted** record inside the importer pipeline and track
`fields << :description`, so the association build has to ride the parent's autosave rather than
calling `update!`. Verify during build.

Neither write path touches `rank` (D5).

### Read path

The five public views become `@game.primary_description&.content`, wrapped in the existing
`if ... present?` guards. `music/albums/lists/show` adds `:descriptions` to its includes — it is the
only site rendering a blurb per row.

`Descriptions::AttributionComponent` renders a credit line and licence link when `license == :cc_by_sa_4`,
using `source_url`. This closes the CC BY-SA gap the legacy site has today: ~461 book pages and all
8,670 Wikipedia-sourced author descriptions.

### Admin

Mirrors `Admin::ImagesController` exactly:

```ruby
resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"   # nested per parent
resources :descriptions, only: [:update, :destroy] do                                  # global
  member { post :set_preferred }
end
```

`turbo_frame_tag "descriptions_list"`, `Admin::DomainScopedAuth` + `require_domain_write!`.

`set_preferred` **demotes the sibling then promotes, inside a transaction.** It cannot mirror
`Image#unset_other_primary_images`, which is an `after_save` that promotes first — under D14's partial
unique index that ordering violates the constraint mid-callback.

**Two things not to copy from `Admin::ImagesController` verbatim:** the polymorphic association is
`describable`, not `parent` (per the `_able` convention), so `params[:parent_type]` and `parent.images`
have no equivalent here. And per D13 this panel is a review-and-select surface, not an authoring one —
`create` exists for override, but the emphasis is view / `set_preferred` / delete.

**Bulk set-preferred by list.** The legacy site's real workflow for `use_description` was a button that
flipped *every book on a list* to Goodreads, because the list was that year's releases and the AI did
not know them. That is the operation to build, not per-record curation: given a list and a target
source, clear `preferred` across the affected rows and set it on the chosen source's rows, in one
transaction. D14's index makes forgetting the clear step raise rather than silently double-flag.

The description field comes out of the nine admin forms. Descriptions become editable only after
create, since the nested panel needs a persisted parent — identical to how images behave today.

### Columns dropped (11, increment e)

`books_books` · `books_authors` · `books_series` · `music_albums` · `music_artists` · `music_songs` ·
`games_games` · `games_companies` · `games_series` · `movies_movies` · `movies_people`

Not dropped — authored config rather than sourced content: `lists`, `penalties`,
`ranking_configurations`, `user_lists`, `categories`, `external_links`.

---

## Failure modes

**Concurrent importer writes** on the same `(describable, kind, locale, source)`: `find_or_initialize_by`
then save is a race. The unique index rejects the loser; rescue `ActiveRecord::RecordNotUnique` and
retry once against the reloaded row. Cheaper than the per-book advisory lock `BookImageMigrator` needed,
because here the index is the guard.

**`upsert_all` bypasses validations** in the backfill, so the unique index and the CHECK constraint are
load-bearing rather than belt-and-braces — the same landmine as `ListPenaltyMigrator`'s static-guard in
PR #165, where the guard had to move into `build_rows`. Rows are validated at build time before upsert.

**Importers writing `rank`** cannot be prevented by the database. Enforced by not exposing `rank` on the
provider/task API surface, plus a test asserting an AI regeneration leaves a `preferred` sibling
untouched.

**Dropping the columns after a bad backfill is unrecoverable.** Gated on the exact-count verification
passing, `bin/snapshot-dev-db.sh --label pre-descriptions` beforehand, and shipped as its own PR (D12).

---

## Testing

- `DescriptionTest` — enums, uniqueness, `source_name`-required-for-`:other`, CHECK constraint
- `Descriptions::ResolverTest` — `preferred` wins; `SourcePriority::ORDER` order; `deprecated` never selected;
  `(kind, locale)` scoping; empty collection → `nil`
- `DescribableTest` exercised through a real model
- Three migrator tests against legacy fixtures: the 198,017-row breakdown and a no-op second run
- `Admin::DescriptionsControllerTest` — CRUD, `set_preferred`, and the `require_domain_write!` denial cases
- **Regression test for the clobber bug:** AI regeneration writes its own row and leaves a `manual`
  `preferred` row untouched
- Updated tests for the five public views and nine admin show pages
- Playwright E2E for the admin descriptions panel (add / set preferred / delete)

Gate before claiming done: `bin/rails test`, `bin/rails test:system`, `bundle exec standardrb`.

---

## Increments

| | Content | Behaviour change |
|---|---|---|
| a | `Description` model, schema, `Descriptions::Resolver`, `Describable`, tests | none |
| b | Three backfill migrators + rake tasks + verification | none |
| c | Write path: AI tasks, IGDB providers, admin panel, strip nine forms | yes |
| d | Read path: five public + nine admin views, `AttributionComponent`, includes | yes |
| e | Drop the eleven `description` columns | separate PR, post-production |

---

## Follow-ups (explicitly out of scope)

- **Retrieval-enabled AI descriptions.** The description tasks run `gpt-5-mini` with no tools and no
  retrieval, and the prompt instructs the model to abstain when it does not know the work — so for a
  2026 release it abstains every time. This is the gap that made Goodreads necessary for recent lists.
  Giving the task web search, or feeding it publisher text as context, produces original text for new
  books and sidesteps the terms question for anything acquired from here on.
- **`review_state` + `reviewed_by`/`reviewed_at`.** 110,400 AI-generated descriptions are about to
  become indexable, which is the shape Google's scaled-content-abuse policy targets. A review state
  would gate which AI text reaches public pages, and doubles as the EU AI Act Art. 50(4) exemption
  artifact ("human review or editorial control"). Deferred as a column that is cheap but implies a
  review queue that is not.
- **`digital_source_type`** (IPTC vocabulary, as Google Merchant Center's `structured_description` uses).
  Needed the day we AI-translate or AI-edit sourced text, where source, licence, and generation method
  diverge. Not today.
- **`content_format`** (`plain`/`markdown`/`html`/`wiki`). Needed if we ingest MusicBrainz wiki markup
  or Discogs BBCode. Everything today is plain text.
- **Versioning.** No audit gem in the app. Prior art says use a general-purpose one on `Description`
  rather than a bespoke versions table, and to steal MusicBrainz's cheap `changelog VARCHAR(255)`
  per-revision edit summary.
- **A `Source` table** carrying priority, licence defaults, and cache policy — so "we trust source X
  more now" is an UPDATE rather than a deploy. Justified at more sources than we have.
- **The books public UI**, parked with its settled decisions in the session carryover note.
