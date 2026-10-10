# Author initials key — design

**Status:** design approved in chat by Shane, 2026-10-09; this document awaits his review.
**Todo item:** "finder initials gap: "J.D. Salinger" fails to match "J. D. Salinger" (found by the
Goodreads replay)", `docs/todo.md`, Data importers.

## 1. Problem

The finders compare author names after lowercasing and Unicode folding only. Initials written two
ways are therefore two different names: `J.D. Salinger` and `J. D. Salinger` never match, so an
import that spells the initials differently from the stored author creates a second author (and,
through the book finder, can miss the book).

Measured on the development database, 2026-10-09 (71,815 authors, read-only):

- **2,241** author names write initials tight (`J.D.`), **402** spaced (`J. D.`), **56** as bare
  letters (`J D Smith`).
- Folding initials as §3 defines joins **212 authors in 64 groups** that differ only in how the
  initials are written: 13 G. K. Chesterton rows, 10 J. M. Coetzee, 8 P. G. Wodehouse, C. S.
  Lewis, T. S. Eliot, J. D. Salinger and others.
- **No group has conflicting birth years**, and **no group was joined by anything other than a
  single-letter initial.** The rule found no false merges in the current data.

### What this is not

The legacy books app worked around initials by matching on surnames alone. That produced many
wrong authors, because a shared surname is not a shared person. This design does the opposite: a
name must still match word for word, and only the spelling of single-letter initials is folded.

## 2. Goals and non-goals

**Goals**

- `J.D. Salinger`, `J. D. Salinger`, `J D Salinger`, `J. D Salinger` and `j.d. salinger` are the
  same name wherever a finder makes an identity decision about a books author.
- Every other difference still keeps two names apart.
- The stored names an import is compared against use the same rule, through an index.

**Non-goals**

- **Surname-only matching.** Never.
- **Initials against full given names** (`J. D. Salinger` vs `Jerome David Salinger`). That is a
  claim about the person, not the spelling, and stays with the evidence paths that already exist:
  stored alternate names, Open Library author keys, and the AI step, whose guidance already says
  "initials or a fuller form of the same person's name is the same author".
- **Bare run-together initials** (`JR Ward`, `AL Kennedy`). Usually initials, but not always; a
  later change can add them after measuring. Until then `JD Salinger` and `J. D. Salinger` stay
  apart.
- **Hyphenated initials** (`J.-P. Sartre` vs `J-P Sartre`). Rare; left as they are.
- **Rewriting display names.** `J.R.R. Tolkien` stays `J.R.R. Tolkien`; only a derived key changes.
- **Merging existing duplicates.** See §6.
- **Titles, music artists, game companies.** Untouched.

## 3. The key

One function, `Services::Text::PersonNameKey.call(text)`, returns the comparison key for a person's
name, or `nil` for a blank name:

1. `QuoteNormalizer`, then `NameNormalizer` (NFKC, every Unicode space folded to one space), then
   `downcase` — exactly today's `FinderBase#normalize`.
2. A **single letter** (a letter not preceded by another letter) **followed by a full stop**
   becomes that letter followed by a space.
3. Runs of spaces squeeze to one; the result is stripped.

| Name | Key |
|---|---|
| `J.D. Salinger` | `j d salinger` |
| `J. D. Salinger` | `j d salinger` |
| `J D Salinger` | `j d salinger` |
| `e.e. cummings` | `e e cummings` |
| `J.R.R. Tolkien` | `j r r tolkien` |
| `Martin Luther King Jr.` | `martin luther king jr.` (multi-letter word untouched) |
| `JD Salinger` | `jd salinger` (not folded, §2) |
| `J. Salinger` | `j salinger` (one initial is not two) |
| `Malcolm X` | `malcolm x` |

The rule is the one measured in §1.

## 4. Where it applies

Only where a finder or importer decides **identity** for a books author. Soft uses (deduplicating
alternate names, the Wikidata label check, collision reports) are left alone: a missed fold there
costs a redundant alternate name, not a duplicate author.

| # | Place | Change |
|---|---|---|
| 1 | `DataImporters::FinderBase` | Two hooks, `title_key(text)` and `creator_key(text)`, both defaulting to `normalize`. `titles_agree?` uses `title_key`; `creators_agree?` uses `creator_key`. Music and games finders inherit the defaults and behave exactly as today. |
| 2 | `DataImporters::Books::Book::Finder` | Overrides `creator_key` with `PersonNameKey`. This covers rule 4 (`exact_match?`), identifier corroboration and rule 2's external-accept check, all of which go through `creators_agree?`, plus the Goodreads replay's `compare_edition.rb`, which calls it too. |
| 3 | `DataImporters::Books::Author::Finder` | Overrides `title_key` with `PersonNameKey` (an author's "title" is its name and alternate names). |
| 4 | `Books::Author::Finder#exact_scope` (SQL) | Matches `books_authors.name_keys && ARRAY[<query keys>]` instead of `LOWER(name) IN` plus the unindexed `unnest(alternate_names)` scan. |
| 5 | `Books::Book::Finder#exact_scope` (SQL, the author half) | Same replacement on the author join. The title half is unchanged. |
| 6 | `Services::Lists::Wizard::Books::Adapter#book_created_from_text_since_match` | Author names compared with `PersonNameKey`; the title comparison keeps `Signature.normalize`. |
| 7 | `Services::Books::OlBackfill::AuthorKeys#key_for` | Names compared with `PersonNameKey` (it assigns an Open Library author key, an identity decision). `Check#authors_agree?` is unchanged: its letters-only `compact` already folds initials, and a title must agree as well. |

## 5. The stored key

- **Column:** `books_authors.name_keys`, `string[]`, `null: false`, `default: []`, with a GIN index.
  It holds the distinct keys of `name` and every alternate name.
- **Maintained by the model:** a `before_validation` on `Books::Author`, after the existing name
  normalizers, sets `name_keys`. Every write path to author names saves through the model (the data
  migration's `AuthorMigrator` uses `save!`, and the weekly legacy sync, `data_migration:sync`,
  runs the same migrator; `Books::Author::Merger` assigns `alternate_names` and saves the target; no
  `insert_all`, `upsert_all` or `update_columns` touches `name` or `alternate_names` — checked
  2026-10-10), so the key cannot go stale.
- **Filled by the migration.** The migration adds the column and index, then fills existing rows by
  calling `Services::Books::RefreshAuthorNameKeys`, which computes keys in Ruby and writes them in
  batches of 2,000 with one `UPDATE ... FROM (VALUES ...)` per batch (about 36 statements for 72k
  authors; seconds). The finder reads the column from the moment the deploy is live, so it must be
  full before then; a separate post-deploy task would leave a window where every exact match
  misses and imports create duplicates.
- **Re-runnable:** `bin/rails books:refresh_author_name_keys` runs the same service. It is needed
  only if the key rule changes. It writes only rows whose keys differ, and reports how many.
- **A blank or unkeyable name** yields an empty array, never an error: a failing migration is an
  outage.
- The existing `lower(name)` index stays; other code still uses it.

## 6. Existing duplicates

The 64 groups (and the 3,085 groups of identically spelled authors the same measurement found)
are already covered by `bin/rails books:goodreads_replay:duplicates`, which is in the launch
sequence (`docs/launch-todo.md`). It groups authors by a looser letters-and-digits key and has the
AI split each group into people, recording merge verdicts for review. This change adds nothing
there; it only stops new duplicates of this kind.

## 7. Testing

- **`PersonNameKey`:** every row of the §3 table, plus nil, blank, curly quotes, a non-breaking
  space and a non-Latin name.
- **`Books::Author`:** saving sets `name_keys` from name and alternate names; changing either
  updates it; duplicates collapse.
- **Author finder:** a query `J.D. Salinger` exact-matches a stored `J. D. Salinger`, by name and
  by alternate name. Negative cases: `J. Salinger`, `Salinger`, `JD Salinger`, `Jr.` vs `JR`.
- **Book finder:** a title-plus-author query with `J.D.` finds the book stored under `J. D.`;
  `creators_agree?` agrees across the two spellings; the same title by `J. Salinger` does not.
- **Music and games finders:** a test pins that their creator comparison is unchanged (the default
  hook).
- **Wizard adapter and backfill `AuthorKeys`:** one test each across the two spellings.
- **`RefreshAuthorNameKeys`:** fills empty rows, leaves correct rows unwritten, reports counts.
- Suites: full `bin/rails test`, `standardrb`. No UI changes, so no E2E.

## 8. Rollout

1. Merge: the migration adds and fills the column during the deploy.
2. **Once, after that deploy:** `docker restart the-greatest-worker`, then
   `bin/rails books:refresh_author_name_keys`. The worker never runs migrations and starts without
   waiting for the web container's `db:prepare`. A worker process that loaded `Books::Author`'s
   columns before the migration committed keeps a column list without `name_keys`, and every
   author save in it raises until it restarts. An author inserted by the old worker while the
   migration held its lock commits with empty keys. The restart clears the first; the refresh
   fills any rows the second left (its `updated` count shows how many, usually 0).
3. After that, nothing manual. Authors the weekly legacy sync (`data_migration:sync`) adds are
   created through `save!`, so their keys are set as they are written.
3. The duplicate cleanup stays where it is: `books:goodreads_replay:duplicates` in the launch
   sequence.
