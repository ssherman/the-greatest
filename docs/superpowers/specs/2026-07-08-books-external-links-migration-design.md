# External Links Migration (legacy `links` → `external_links`) — Design

**Status:** Approved 2026-07-08.
**Scope:** One migration increment on top of the merged books data (Phase 1a/1b + editions + identifiers + categories + ISBN + **users**). Migrate the legacy `links` table into the polymorphic **global** `ExternalLink` model, parented to `Books::Book` (preserved ids), with `submitted_by` resolving to the now-migrated users. Fresh ids. No schema change.
**Parent design:** `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`.
**Depends on:** the merged `users` increment (`submitted_by_id → users.id`) — that FK is why this increment waited.

## Goal

Get all 13,404 legacy `links` rows into `external_links` as `Books::Book`-parented links, faithfully preserving url, name, submitter, and timestamps, with a `source` inferred from the URL host. The load is idempotent and re-runnable.

## Legacy data (local restore, introspected 2026-07-08)

`links`: **13,404 rows**. Columns: `id, name, url, user_id, description, book_id, created_at, updated_at`. Schema declares `url`, `user_id`, `book_id` all `NOT NULL`.

Data-quality facts that drive the design:

| Fact | Value | Handling |
|---|---|---|
| Cardinality | **exactly 1 link per book** (13,404 distinct `book_id`) | — |
| Submitter | **all 13,404 rows are `user_id = 1`** (admin; migrated, present) | `submitted_by_id = 1` |
| Orphan book FKs | **0** — every `book_id` exists in `Books::Book` | required `belongs_to :parent` fails loud if ever violated |
| Orphan user FKs | **0** — user 1 present | DB FK on `submitted_by_id` fails loud if ever violated |
| `name` | present on every row, but **the constant `"Wikipedia"`** — even on the 15 non-Wikipedia links | **migrated verbatim** (D-name) |
| `description` | **all null/blank** | → nil |
| `url` scheme | all present; **1 row** (`en.wikipedia.org/wiki/The_Hunting_of_the_Snark`) lacks `http(s)://` and fails the model's URL format validation | **normalized** (D-url) |
| Hosts | ~99.9% Wikipedia (13,390 across en/de/es/nl/fr, incl. 3 non-ASCII/scheme-less); rest: 7 books.google, 3 time.com, 3 powells, 1 goodreads | host→`source` map (D-source) |
| Non-ASCII urls | 2 Wikipedia urls contain `ö`/`è` and make `URI.parse` **raise** | host extracted by string ops, not `URI.parse` (D-source) |
| Duplicates | **0** duplicate `[book_id, url]` | natural key clean |
| Timestamps | `created_at` spans **517 distinct days (2022→2026)**; `updated_at == created_at` everywhere | **preserved** (D-write) |
| Target table | `external_links` already holds 15,677 rows (all `amazon`, all non-`Books::Book`) | Books links are a clean insert; no collisions |

## Decisions

- **D-write — per-row AR `Migrator` subclass, not `BulkUpsertMigrator`.** `find_or_initialize_by(parent_type: "Books::Book", parent_id: book_id, url:)`, assign, `save!` (mirrors `EditionMigrator`'s per-row style). Rationale: the natural key `[parent_type, parent_id, url]` has **no unique index** on `external_links`, and `upsert_all` (which `BulkUpsertMigrator` requires) needs one — adding a unique index to a shared, 4-domain, 15,677-row production table is out of scope and higher blast-radius than this increment warrants. Per-row AR gives idempotency via `find_or_initialize_by`, **runs model validations** (fail-loud for free), and 13,404 rows is trivial per-row (books/editions already migrate per-row at larger scale). Fresh ids (links are not id-preserving; only `Books::Book` and `User` preserve ids).
- **D-timestamps — preserve legacy `created_at`/`updated_at`.** They span 517 days (not a single bulk import), so they carry real signal. With per-row AR, assigning **non-nil** `created_at`/`updated_at` before `save!` means AR's timestamp callback leaves them untouched on create (`_create_record` only fills a timestamp when it reads back falsy). On an idempotent re-run the record is found and unchanged, so `save!` is a no-op and timestamps stay put.
- **D-source — infer `source` from a robustly-extracted host.** Extract host by string ops (strip scheme, take up to the first `/`, downcase, drop leading `www.`) — **not** `URI.parse`, which raises on the two non-ASCII Wikipedia urls. Map:
  - host ends with `wikipedia.org` → `wikipedia`
  - host is/ends with `goodreads.com` → `goodreads`
  - host contains `amazon.` → `amazon`
  - host is/ends with `bookshop.org` → `bookshop_org`
  - else → `other`
  (`musicbrainz`/`discogs` are music-domain and do not occur.) Verified over the real data with this exact logic: **13,390 `wikipedia`, 1 `goodreads`, 13 `other` (7 books.google, 3 time.com, 3 powells), 0 amazon/bookshop**.
- **D-source_name — set `source_name` to the host for `other`-source rows only.** `ExternalLink` validates `source_name` presence when `source_other?`; the host (e.g. `"books.google.com"`) is a deterministic, meaningful value. `nil` for all non-`other` rows.
- **D-name — migrate `name` verbatim** (owner decision, 2026-07-08). Every row keeps its legacy `"Wikipedia"` label, including the 15 mislabeled non-Wikipedia rows. This is a faithful migration of what the old site displayed; the mislabeling is pre-existing legacy data, not introduced here, and correcting it is out of scope. Keeps the migrator trivial.
- **D-category — `link_category = :information` for all rows** (owner decision, 2026-07-08). Accurate for the overwhelming Wikipedia-reference majority and reasonable for the ~15 others (all book-reference links). Simple constant.
- **D-url — normalize scheme-less urls** (owner decision, 2026-07-08): if a url does not start with `http(s)://`, prepend `https://`. Fixes the single offending row and acts as a general safety net so a cosmetic legacy defect never aborts the run.
- **D-public — `public = true`** for all (design-doc default; these are curated reference links).
- **D-fail-loud — rely on AR validation + DB FK, both wrapped by the base rescue.** `belongs_to :parent` is required (`belongs_to_required_by_default = true`, `parent` not optional — confirmed), so a missing `Books::Book` raises `Validation failed: Parent must exist` on `save!`. `submitted_by_id` has a DB FK to `users`, so a missing user raises on insert. The base `Migrator`'s per-row rescue re-raises naming the **legacy link id** (`"External link migration failed at legacy id=… "`). No custom preload guard is needed — per-row AR surfaces both FK failures loudly and precisely. (Contrast `CategoryItemMigrator`, which needed an explicit guard only because its bulk `upsert_all` path runs no validations.)

## Schema change

**None.** `external_links` already exists with the needed columns and polymorphic `parent`. No new index (D-write).

## Source → target mapping (`links` → `external_links`, fresh id)

| new column | legacy source | handling |
|---|---|---|
| `id` | — | fresh (auto) |
| `parent_type` | (constant) | `"Books::Book"` |
| `parent_id` | `book_id` | direct (books preserve id); required-`belongs_to` validates existence |
| `submitted_by_id` | `user_id` | direct (users preserve id); DB FK enforces existence |
| `url` | `url` | **normalized**: prepend `https://` if scheme-less (D-url) |
| `name` | `name` | **verbatim** (D-name) — `"Wikipedia"` for every row |
| `description` | `description` | direct (all nil in practice) |
| `source` | derived from host | host→enum map (D-source) |
| `source_name` | derived from host | host string for `other` rows only, else nil (D-source_name) |
| `link_category` | (constant) | `:information` (D-category) |
| `public` | (constant) | `true` (D-public) |
| `created_at` / `updated_at` | same | **preserved** (D-timestamps) |

Left unset (defaults): `click_count` (0), `metadata` (`{}`), `price_cents` (nil).

## Migrator

`Services::BooksMigration::ExternalLinkMigrator` — a **`Migrator`** (per-row AR) subclass:

- `legacy_model = LegacyBooks::Link` (new read-only model, `self.table_name = "links"`).
- `model_key = "ExternalLink"`.
- `upsert_row(attrs)`: normalize url → `find_or_initialize_by(parent_type: "Books::Book", parent_id: attrs["book_id"], url: normalized_url)` → assign `name`, `description`, `submitted_by_id`, `source`, `source_name`, `link_category: :information`, `public: true`, and legacy `created_at`/`updated_at` → `save!`.
- Host extraction + source mapping + source_name as small private helpers (or a thin transformer, matching the `*_transformer.rb` house style where the mapping is non-trivial). Given the host/source logic is the only real logic, a companion `ExternalLinkTransformer` mirroring `EditionTransformer` is optional; a couple of private methods on the migrator are sufficient. **Implementation may choose** whichever reads cleaner; tests target public behavior either way.
- No `finalize` (no counter caches; `external_links` has none for `Books::Book`).

Idempotent on the natural key `[parent_type, parent_id, url]` via `find_or_initialize_by`.

## Orchestration

Add `data_migration:external_links` task calling `ExternalLinkMigrator.call`. Insert `:external_links` into `data_migration:all` **after `:users`** (needs `submitted_by`) **and after `:books`** (needs the `Books::Book` parents) — e.g. at the end of the current chain, `[:languages, :users, :authors, :books, :book_authors, :editions, :identifiers, :categories, :category_items, :external_links]`.

## Testing (Minitest + Mocha, stub `legacy_each`)

Public-behavior tests, stubbing the legacy stream (`legacy_each`) so no legacy connection opens. Use existing `Books::Book` + `User` fixtures for parents/submitters.

- Maps a fully-populated legacy row → correct `external_links` row: `parent` = the `Books::Book`, `submitted_by` = the user, url/name/timestamps preserved, `public = true`, `link_category = information`.
- **Source mapping** per host: `en.wikipedia.org`/`de.wikipedia.org` → `wikipedia`; `goodreads.com` → `goodreads`; `books.google.com`/`time.com`/`powells.com` → `other` **with `source_name` = host**; an `amazon.` url → `amazon`; a `bookshop.org` url → `bookshop_org`.
- **Non-ASCII url** (contains `ö`/`è`) classifies as `wikipedia` without raising (proves host extraction avoids `URI.parse`).
- **Scheme-less url** is normalized (`https://…`) and the row saves (passes URL format validation).
- Legacy `created_at`/`updated_at` **preserved** (not overwritten with "now").
- **Idempotent:** re-running the same row leaves `ExternalLink.count` unchanged and does not duplicate.
- **Fail-loud:** a row whose `book_id` has no `Books::Book` raises, and the error names the legacy link id (base rescue wraps `belongs_to :parent` validation).
- `source_name` is nil for non-`other` sources.

## E2e verification (controller-run against the real legacy DB)

Reset dev DB to the migrated baseline, run `data_migration:external_links`, then verify:
- `ExternalLink.where(parent_type: "Books::Book").count == 13,404` (was 0); total rises by 13,404.
- `source` distribution matches expectation (13,390 `wikipedia`, 1 `goodreads`, 13 `other`); every `other` row has a non-null `source_name`; **no** `Books::Book` link has a null/invalid url.
- All `submitted_by_id == 1`; every `parent_id` resolves to a real `Books::Book`.
- Legacy `created_at` min/max preserved (2022-11-05 … 2026-06-20); `link_category` all `information`; `public` all true.
- The pre-existing 15,677 `amazon` (non-Books) rows are untouched.
- **Idempotent:** a second run leaves the Books::Book `external_links` count unchanged.
- Full suite green; standardrb + brakeman clean.

## Out of scope
- Any unique index / DB constraint on `external_links` `[parent, url]` (D-write).
- Correcting the 15 mislabeled `"Wikipedia"` names (D-name).
- `click_count`/`price_cents`/`metadata` population (no legacy source).
- Non-book link parents (legacy `links` are 100% book-parented).
- Music/Movies/Games external links (separate domains/sources).

## References
- Parent design: `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`
- Prior increment (template): `docs/superpowers/specs/2026-07-07-users-migration-design.md`
- `Migrator` base (per-row AR): `app/lib/services/books_migration/migrator.rb`; `EditionMigrator` (per-row style): `app/lib/services/books_migration/edition_migrator.rb`
- `ExternalLink` model: `app/models/external_link.rb`
- Orchestrator: `lib/tasks/data_migration.rake`
