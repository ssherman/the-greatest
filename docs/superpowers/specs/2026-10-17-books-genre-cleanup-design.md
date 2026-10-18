# Books genre cleanup and the audience type

Date: 2026-10-17. Follows `2026-10-11-books-category-cleanup-design.md` (Spec A), which cleaned
subjects and locations and left genres alone.

## 1. Why

Genres are the most used category axis (filters, saved searches, recommendations, similar books,
the global canon, WorldCat). They came from Goodreads, whose "genres" are the most popular reader
shelves, so they mix every kind of label. Measured in dev (a production copy) on 2026-10-17:

- 171 live genres, 693,800 book links, all `legacy` source. 92 genres have 1,000+ books.
- Mixed into them: audience (`Children's books` 5,276, `Young adult` 5,197, `Adult` 4,887,
  `Middle Grade` 2,022, `teen`), time periods (`Victorian`, `Elizabethan Period`, `Georgian`,
  `Anglo Saxon`, `Ancient`, `Prehistoric`, `21st Century`), moods (`Dark`, `Cozy`), romance tropes
  (`Slow Burn`, `Forced Proximity`, `Second Chance`), reception (`Banned books`, `Cult Classics`,
  `Summer Reads`), format (`Ebooks`), creator identity (`Latino`, `Latinx`, `Hispanic`, `Aapi`),
  places and noise (`Agerstown`, `South dakota`, `Suisse`, `Magrathea`, `Apple`, `Own`), and twins
  (`Manga Comics`/`Comics Manga`, `Thriller & Suspense`/`Thriller Suspense`).
- `Drama` (5,838) is a Goodreads "dramatic" shelf: only 942 of its books are also `Plays`; the
  rest are mostly novels, romance and manga, with some untagged real plays.
- 832 of 5,415 saved searches and 11 of 33 recommendation settings reference a genre.

Goal: a tight, deliberate genre list (about 40–60), a new **audience** type, and every current
genre given exactly one reviewed fate, without breaking anything that reads categories.

## 2. Prior art and the facet model

Library of Congress keeps separate vocabularies for subjects (what a book is about, with places
and periods as subdivisions), genre/form (what a book is) and demographic groups (who it is for,
who made it). FAST (OCLC, the source of our WorldCat data) facets topic, place, period, event and
genre/form. Thema (book trade) adds qualifiers for place, period and interest age. BISAC puts
juvenile and young adult in separate top-level branches. StoryGraph adds reader-voted mood and pace.

The test this spec uses everywhere: **a genre is what the book is; a subject is what it is about.**

| type | holds | change |
|---|---|---|
| genre | form (short stories, plays, graphic novels, letters and diaries, picture books) and reader conventions (mystery, fantasy, memoir, true crime, cookbooks) | tightened |
| audience | `Children's`, `Middle Grade`, `Young Adult` | **new**, flat |
| subject | topics, time periods, LGBTQ+, real moods/tropes/reception labels worth keeping | receives retypes |
| location | places | receives a few merges |

### The audience values

Exactly three, fixed by this spec rather than drafted by the AI:

| audience | ages | from today's genres |
|---|---|---|
| Children's | about 0–8 | `Children's books` (5,276), retyped and renamed |
| Middle Grade | about 8–12 | `Middle Grade` (2,022), retyped |
| Young Adult | about 12–18 | `Young adult` (5,197), retyped and renamed; `teen` (187) merges in |

These are the US trade's bands (BISAC splits Juvenile from Young Adult; ONIX calls the second
"Teenage", 12–18; publishers market Middle Grade as 8–12). Board books, picture books, early readers
and chapter books are forms or reading levels, not audiences: `picture books` stays a genre. New
Adult is a romance marketing label none of our books carry. No audience means a general (adult)
readership; nothing is ever tagged Adult.

WorldCat has no usable audience value: its records' `audience` field is empty in every sample, and
the MARC fixed field (preschool, primary, pre-adolescent, adolescent, adult, general, specialized,
juvenile) is coded almost always as plain "juvenile", about 0–15. Audience there lives in subject
wording ("Wizards Juvenile fiction", "Young adult fiction", "JUVENILE FICTION Fantasy & Magic"),
which §7 handles.

Decided and out of scope: no `Adult` audience; no time-period type (periods become subjects,
revisit in Spec B); no mood, pace or trope types.

## 3. Rules for the genre list

These go into both AI prompts (§5) and are what the reviewer checks against.

1. A genre names what kind of book it is (form or a convention readers shelve by).
2. Fold a subgenre into its parent unless readers widely shelve by it and it holds enough books
   to stand alone. Aim for about 40–60 genres. "Widely shelved" means in today's book market, not
   only in our catalog, which leans to the canon: `Romantasy` (225 books here, one of the
   best-selling genres now) is kept.
3. Topics and time periods become subjects.
4. Places merge into an existing location, otherwise are deleted. A genre never creates a place.
5. Audience goes to one of the three audiences (§2). `Adult` is not an audience: the `Adult` genre
   is deleted, or merged into `Erotica` if that is what its books mostly are.
6. Moods, tropes and reception labels become subjects when they are real topics (`Banned books`),
   otherwise are deleted (`Summer Reads`, `Slow Burn`).
7. Formats (`Ebooks`) are deleted.
8. Creator identity (`Latino`, `Latinx`, `Hispanic`, `Aapi`) is deleted.
9. LGBTQ+ is a subject: `Gay fiction` and `Lesbian Fantasy` merge into the existing `LGBTQ+`
   subject (893 books).
10. `Drama` is deleted as a genre; its WorldCat terms point at `Plays` (§7). Books that are plays
    but carry neither tag are left for Spec B's per-book pass.
11. The four protected book-type genres (`Fiction`, `Nonfiction`, `Religion & Spirituality`,
    `Poetry`, `Books::Category.protected_ids`) are on the list, unchanged: no rename, retype, merge
    or delete. Nothing merges into `Fiction` or `Nonfiction`; they are the book-type split.
12. Names are consistent title case (`Science Fiction`, `Historical Fiction`).
13. A genre that saved searches or recommendation settings use prefers `subject` over `delete`
    (a retype keeps its id, so they keep working).
14. A genre that combines two things readers would look for separately is split (§4), so its books
    get both: `Science Fiction Fantasy` → Science Fiction and Fantasy, `Rom Com` → Romance and
    Humor, `Hockey Romance` → Romance and the Hockey subject. A compound that names one convention
    (`Thriller & Suspense`) is kept or renamed, and one whose second half adds nothing
    (`Cozy Fantasy`) merges.
15. A kept genre that is by definition also other list genres names them in `also:`, so its books
    are found under those too: `Romantasy` is kept with `also: [Romance, Fantasy]`. Use it only
    when every book of the genre is necessarily the others; otherwise split.

## 4. The plan file

All decisions live in one committed file, `web-app/config/books/genre_plan.yml`, drafted by AI in
development, edited by Shane, reviewed in the PR, and applied unchanged in production. Production
makes no AI calls. Dev and production share category ids (dev is a production restore).

```yaml
version: 1
run: genres-2026-10
genres:                 # the list; Shane owns this part
  - name: Science Fiction
    definition: Stories built on speculative science or technology.
audiences:              # fixed: the three in §2; draft writes them, the validator requires them
  - name: Children's
    definition: Written for readers up to about age 8.
  - name: Middle Grade
    definition: Written for readers about 8 to 12.
  - name: Young Adult
    definition: Written for readers about 12 to 18.
decisions:              # exactly one per live genre, keyed by category id
  41231: {name: "Science fiction", action: rename, to: "Science Fiction", reason: "..."}
  41290: {name: "Space Opera", action: merge, into: "Science Fiction", reason: "..."}
  40112: {name: "Children's books", action: audience, as: "Children's", reason: "..."}
  41377: {name: "Vegetarian", action: subject, reason: "..."}
  41402: {name: "Victorian", action: subject, as: "Victorian Era", target_id: 23311, reason: "..."}
  41180: {name: "Gay fiction", action: subject, as: "LGBTQ+", target_id: 20981, reason: "..."}
  41455: {name: "South dakota", action: location, as: "South Dakota", target_id: 3121, reason: "..."}
  41501: {name: "Ebooks", action: delete, reason: "..."}
  40870: {name: "Drama", action: delete, worldcat: "Plays", reason: "..."}
```

Actions and what apply turns them into (`CategoryCleanupDecision` rows, new stage `genres`):

| action | meaning | decisions |
|---|---|---|
| `keep` | already on a list under this exact name; optional `also:` list names (rule 15) | keep; with `also:`, its books are linked to those genres too (no per-book check: the definition implies them) |
| `rename` | on a list under the name in `to:` | rename |
| `merge` | `into:` names a list entry | merge (target = the category that becomes that entry) |
| `audience` | becomes the audience in `as:` | retype to audience, plus rename when `as:` differs |
| `subject` | `target_id` set: merge into that live subject; otherwise retype (plus rename if `as:` differs) | merge, or retype (+ rename) |
| `location` | `target_id` required: merge into that live location | merge |
| `delete` | soft delete | delete |
| `split` | every book gets every `into:` target (below) | split (merge into, or rename to, the primary; links added to the rest) |

### Combined genres: `split`

Some genres are two things at once: `Science Fiction Fantasy` (252), `History and Politics`
(12,605), `Science Nature` (4,140), `Art and Photography` (355), `Romantasy` (225), `Rom Com` (108),
`Lesbian Fantasy`, `Hockey Romance`, `Military Thriller`. A merge would put their books under one
half only, and once merged the books can no longer be told apart, so splitting happens here.

```yaml
  41611: {name: "Science Fiction Fantasy", action: split, into: ["Science Fiction", "Fantasy"]}
  40977: {name: "History and Politics", action: split,
          into: ["History", {subject: "Politics", target_id: 20412}],
          worldcat_terms: {"History": ["History"], "Oral history": ["History"], "Geschichte": ["History"]}}
  41702: {name: "Hockey Romance", action: split, into: ["Romance", {subject: "Hockey", target_id: 31187}]}
```

- **Each book gets only the targets that fit it, checked book by book.** The combined genres are
  noisy: of `Science Fiction Fantasy`'s 252 books, 63 carry neither `Science fiction` nor `Fantasy`,
  and they include *The Fabric of the Cosmos* (physics) and a Captain Marvel comic; a blind split
  would also file *The Lord of the Rings* under Science Fiction. `split_check` (§5) decides per
  book, in development, and its answers are committed (`config/books/genre_split_assignments.csv`:
  `book_id,category_id,targets`). A book can get one target, several, or none (it loses the tag).
  A book the AI does not recognise keeps every target, so no information is lost. A book on the
  genre that is missing from the file (added to production after the dev copy) gets every target,
  and `apply` prints how many.
- `into:` entries are list names (genre or audience) or existing subjects (`target_id` resolved as
  for `as:`); never locations.
- The first entry is the primary. If another decision already produces that list entry (a `keep`
  or `rename`), the split genre merges into it, so saved searches and old URLs follow it there. If
  nothing else produces it, the split genre is renamed to it, keeping its id (`History and
  Politics` becomes `History`, and the searches that used it now mean History).
- A name like `Thriller & Suspense`, `Comics & Graphic Novels`, `Folklore & Fairy Tales` or
  `Religion & Spirituality` names one convention, not two, and is not split. A compound whose
  second half is redundant (`Cozy Fantasy`, `Second Chance Romance`) merges.
- `worldcat_terms` (written by `map`, §5) says, for each WorldCat term that targets this genre
  today, which of the split's genre or audience targets it now supports (§7).

The applier gains a `split` action (enum value 6) and the decision table an `extra_target_ids`
`bigint[]` column (default `{}`), filled from the non-primary targets. Splits run first, before any other phase, each in one
transaction: renaming-mode splits by id, then merging-mode splits by id. The Applier's order is
then plain renames, merge, retype, parents, set_parent, delete, and a final pass for keeps and
renames that carry extra targets (`also:`). An earlier design ran splits in the merge phase; a
merge into a renaming split's primary (World History into History, where History is "History and
Politics" renamed) then ran before the split, so the merged books looked like unanswered split
books and got every target, Politics included. Renames with `also:` wait for the final pass so
books merged into them get the `also:` targets too, as they do for a kept genre. Each split:

1. For each book on the genre, add links to its assigned targets (skipping links that already
   exist, keeping the original link's `source`).
2. Merging mode: remove the genre's own links, then merge the now-empty genre into the primary, so
   it is soft-deleted with `merged_into`, its aliases move, and saved searches, old URLs and legacy
   links follow it. Renaming mode: remove the links of books not assigned the primary, then rename.

Rulings made while building this:

- **A split acts only on its own books.** Before any split runs, each pending split's current books
  are written into its `split_assignments` (a book with no answer gets every target) with a
  `_materialized` marker, committed before the first split. A split then acts only on books listed
  there; links that arrive from another split stay on the genre untouched. This survives a crash
  or a retry.
- **Targets are checked, never followed.** A split, or a keep or rename with extra targets, fails
  its decision when any target is missing, deleted or merged, when an answer names an id outside
  the split's targets, or when an answer is not a list. A failed decision is recoverable; silently
  dropping a book's tag is not.
- **Merging mode keeps a book's independent link.** A book that already had its own link to the
  primary keeps it even when its answer leaves the primary out. "*The Lord of the Rings* must not
  end on Science Fiction" means not through the split.
- **`also:` is not transitive.** If R is also K and K is also F, R's books are not guaranteed to
  reach F.

It is terminal like a merge for `supersede_conflicting` and the staleness check. Every book on the
genre is requeued for reindexing (the Merger's own requeue sees no items once the links are gone).

Legacy sync: a new legacy link to a split genre would otherwise reach only the primary (through the
merge redirect) or the renamed genre. `CategoryItemMigrator` loads the applied decisions that carry
`extra_target_ids` (splits, and keeps or renames with `also:`) once per run and also links those
targets, skipping links that already exist. For a split this gives a new book every target, since
the sync cannot check it. Extra targets are looked up by the link's own new-app id and by its
redirected target; the redirected lookup takes only keep and rename extras, so a split's extras
reach only links on the split genre itself.

Known gap, accepted: a merging-mode split's pre-existing aliases (categories merged into the
combined genre before the plan) are flattened onto the primary by the Merger, so a new legacy book
linked through one reaches only the primary during the sync window. The same holds for the
pre-existing aliases of a renaming split. The sync ends at launch.

A `keep` or `rename` with `also:` stores the `also:` genres in `extra_target_ids` too; the applier
links the genre's books to them after the keep or rename, skipping existing links.

`target_id` is resolved when the file is written (§5) by exact name, then alternative name,
against live subjects or locations, and kept alongside `as:` so the reviewer sees both. The
optional `worldcat:` key overrides where this genre's WorldCat terms go (§7).

### Checks (`Services::Books::GenrePlan::Validator`)

Run by `apply`, and by a test over the committed file. Any failure stops everything; nothing is
written.

- Every live genre has exactly one decision; every decision's `name` matches its live row; a live
  genre missing from the file is named in the error (it means the plan is out of date).
- `audiences:` is exactly Children's, Middle Grade and Young Adult (§2).
- Every `into:` names a list entry; every `as:` for `audience` names an audience entry.
- Every list entry ends as exactly one live category of its type: one `keep`, `rename` or
  renaming `split` for each genre entry, one `audience` decision (or `keep` of an existing
  audience) for each audience entry.
- A `split` has at least two `into:` targets, no duplicates, and no location; its subject targets
  have live `target_id`s; every `worldcat_terms` target is one of its genre or audience targets.
- A split may rename only when its primary is on the genre list. An audience-name primary must be
  produced by an `audience` decision or an existing live audience, and the split then merges into
  it. Existing live audiences count before splits. An `audience` decision plus an existing live
  audience of the same name is an error (two producers).
- Genre and audience list names are unique within and across both lists, case-insensitively.
  `also:` may not name Fiction or Nonfiction.
- A split's WorldCat term may be answered `[]`: it supports none of the split's halves, and
  `retarget_worldcat` writes it as a `drop` with reason `not_a_genre`.
- `run:` is not blank, and a run that already has decisions from another stage is refused (checked by `apply`, not the validator).

- `also:` appears only on `keep` and `rename`, and names genre list entries other than the
  genre's own.
- The four protected genres are `keep`. Nothing merges into `Fiction` or `Nonfiction`.
- Every `target_id` is live, of the stated type, and still has the stated name.
- `location` always has a `target_id`.
- Every `worldcat:` names a genre or audience entry.

(A check that no merge or split target is itself merged, split, retyped or deleted was dropped.
Targets are list entries, and list entries are produced only by keep, rename, a renaming split or
an audience retype, so a merge into an audience-retyped category, `teen` into Young Adult, is
legitimate.)

## 5. Commands

All in `lib/tasks/genre_cleanup.rake`, namespace `categories:genres`. `draft` and `map` use the
`:premium` role (`gpt-6-astra`), about ten calls; `split_check` uses `:standard` (below). The
whole job stays well under `CostGuard`'s limit.

1. **`draft`** (dev). One call, `Services::Ai::Tasks::Books::GenreDraftTask`. Input per live genre:
   name, book count, five sample titles (`Services::CategoryCleanup::SampleTitles`, oldest ids, which skew to well-known books), saved-search and recommendation-setting
   reference counts; plus the §3 rules. Output schema: `genres` (name, definition) and `notes` (what
   happens to each large genre not kept). The audiences are fixed by §2, so the AI does not draft
   them: the `audiences:` section is written from `PlanFile::AUDIENCES`. Writes both sections of the
   plan file and prints the notes. Refuses to overwrite a file that already has
   `decisions:` unless `FORCE=1`.
2. Shane edits the lists.
3. **`map`** (dev). `Services::Ai::Tasks::Books::GenreMapTask`, batches of 30, with the lists and
   their definitions in the prompt and the same per-genre facts as `draft`. An `into:` or audience `as:`
   that is not on the lists fails the whole batch (rejected by validation in the task, not by schema
   enums: `OpenAI::BaseModel` classes are static, so per-call enums are not possible; the batch is
   retried on the next run, as `WorldCatGenreMappingTask` does). Resolves `as:` to
   `target_id` (§4); a `location` with no match is written as `delete` with the reason "no such
   location: X" for the reviewer. For a `split`, the batch also receives the WorldCat terms that
   target that genre in `genre_map.yml` and returns `worldcat_terms`. Writes `decisions:`.
   Resumable: genres already in `decisions:` are skipped, so it also covers genres added later.
4. **`split_check`** (dev). `Services::Ai::Tasks::Books::GenreSplitCheckTask`, `:standard` role,
   10 books per call. For each book on a `split` genre: title, authors, year, description when we
   have one, and its other genres; the answer is a subset of that split's targets, or `unknown`.
   Writes `config/books/genre_split_assignments.csv`. Resumable by book. About 17,700 books
   (`History and Politics` 12,605 and `Science Nature` 4,140 are most of them), so about 1,800
   calls, a few dollars. `report` prints, per split, how many books got each target, several, none
   and `unknown`, with 20 sample titles per outcome.
5. Shane reviews and edits the file in the PR. **`report`** prints the decisions grouped by
   action with book counts and, for every `delete`, the saved-search and recommendation-setting
   reference counts.
6. **`retarget_worldcat`** (dev). Rewrites `config/worldcat/genre_map.yml` from the plan (§7).
   The rewritten map is committed in the same PR as the plan.
7. **`apply`** (production; Shane runs it). Runs the validator, writes the stage-`genres`
   decisions for `run:` (idempotent: decisions already written for the run are not duplicated),
   runs `Services::CategoryCleanup::Applier` for the run, then removes the ids of applied deletes
   from saved searches and recommendation settings (§6) and prints which records it changed.
   Re-running changes nothing.

   A re-run skips the validator and the builder once the run has `genres` decisions, so edits to
   the plan need a new `run:` value. Failed decisions are not retried automatically. `apply` exits
   non-zero while any decision of the run is failed or stale, and prints a remedy for each: failed
   means fix the cause, reset the decision to proposed and run again; stale means the category
   changed after the plan was built, so handle it by hand and mark the decision rejected.
   `report` prints the combined count of saved searches and recommendation settings (the plan
   file's key stays `saved_searches`). It ends with a "slug conflicts" block listing each rename,
   renaming split and audience rename whose clean slug is held by a live category the plan does not
   delete or merge, naming the holder, so the owner can fix the plan first.

   **Slug reclaim.** A rename regenerates the slug and friendly_id adds a UUID when the clean one is
   taken: by a soft-deleted category (`Children's` holds `children-s`), by a twin the same run merges
   in later, or by a history row. The last Applier step (after deletes and the keep/rename-with-extras
   pass) gives every category the run renamed the clean slug of its current name when only dead
   categories hold it: the dead holders move to `<slug>-<id>`, their history rows for the slug go, and
   the renamed category's old slug stays in history. A live holder keeps the slug. It is idempotent
   and requeues the categories it changed for search. `retarget_worldcat` leaves a term already in final form
   alone, so a second run gives the same file; once retargeted, split terms no longer point at the
   split genre, so changing a split's `worldcat_terms` means restoring `config/worldcat/genre_map.yml`
   from git first.

   Overrides: `PLAN=path` and `ASSIGNMENTS=path` replace the default plan and split-answers files on
   any of the commands (used by the tests and by rehearsals).

`CategoryCleanupDecision::STAGES` gains `genres`. The applier is used as it is: its staleness
check, merge-cycle breaking, the Merger's refusals, soft deletes and search reindexing all apply.
A rename paired with a retype survives `supersede_conflicting` already.

## 6. Everything that reads categories

Principle: an audience behaves exactly as a genre does today wherever genres score or match, and
appears as its own group wherever types are shown. Retypes keep ids, so stored ids keep working.

| area | today | change |
|---|---|---|
| Category enum (`app/models/category.rb`) | 6 types | add `audience: 6`; the admin type select picks it up |
| Search index (`Books::Book#as_indexed_json`, `book_index.rb`) | `genre/subject/location_category_ids` | no `audience_category_ids` field. Audience ids are written into `genre_category_ids` and counted in `similarity_category_count` (through `Books::Book::SCORING_TYPE_OF`), so scoring and the category filter are unchanged. Nothing would query a separate field (filters use `category_ids`, scoring uses `genre_category_ids`), and adding a mapped field to the live index needs a rebuild |
| Similar books (`book_similar.rb`), recommendations (`adapter.rb`, `profile_builder.rb`, `book_recommendations.rb`, `genre_calibration.rb`) | genre-only paths | audience is treated as genre (`Books::Book::SCORING_TYPE_OF` / `GENRE_SCORED_TYPES`); the taste panel shows audiences under Genres, because recommendations see them as genres and a separate label would mean carrying the real type through the profile for no scoring benefit |
| Saved searches, recommendation settings | ids, type-agnostic; merges followed at query time | no change for retype or merge. Applied deletes: ids removed from included and excluded lists by `apply` (an included deleted id would otherwise return nothing). Label copy "genres" becomes "categories" |
| Filter modal (`filter_facets_query.rb`, `filters_controller.rb`, `filter_modal_component`) | default list shows genres only | add an Audience group; the search placeholders are unchanged (14 Playwright selectors depend on them), and the axis hint becomes "Genre, audience, subject, or setting" |
| Page titles (`filter_title.rb`) | genre/subject/location only | audience contributes ("The Greatest Young Adult Books…") |
| Global canon (`global_canon_params.rb`, `global_canon_controller.rb`) | exclusions must be `genre` slugs; unknown slug 404s | accept genre and audience slugs; picker searches both; a merged or renamed slug 301s to the current one through `CategorySlugResolver`, as `FilterParams` does |
| `/categories` (`BrowseQuery::TYPES`, `BrowseController::TITLES`, the route's `browse_filter`, `BrowsePath`) | genre/location/subject tabs | add an audience tab, exempt from the 5-ranked-book minimum like genre |
| Book page (`books_controller.rb` `CATEGORY_TYPE_ORDER`) | unknown types last | order genre, audience, subject, location |
| CSV export (`csv_exports/books/ranked_book_row.rb`) | genres/subjects/locations columns | add an audiences column |
| Subject cleanup prompt (`subject_task.rb`) | deletes audience-like subjects | keeps deleting audience-named subjects, now naming the type ("an audience ... which is its own category type") |
| Public API | `category_type` is a free string | document `audience` in the OpenAPI description |
| Legacy `/genres/:id` | resolves merges, 404s plain deletes | unchanged; deleted junk genres 404 |

Unchanged and verified: `FilterParams` (slug lookup has no type), `RankedBooksQuery`, saved-search
and recommendation criteria storage, the protected-category lookups (by name, as `genre`), the
reindex callbacks (`saved_change_to_category_type?` requeues a retyped category's books).

Legacy sync: in sync mode an already-mapped category keeps its new type, name and deleted flag;
links to a merged category land on its target; links to a deleted one are dropped. `SavedSearchMigrator` and `RecommendationConfigMigrator`
likewise drop category ids whose category is deleted and not merged (merged ids stay, since queries
follow them); without that, the weekly sync would put deleted genre ids back into criteria after
`apply` cleaned them. A full
non-sync `data_migration:all` would revert the retypes, and it no longer runs after the
switch-over.

## 7. WorldCat

The map (`config/worldcat/genre_map.yml`, 4,261 terms) names genres by name, and production steps
14–15 of launch-todo §9 (aliases and backfill) have not run. This cleanup must land first.

- `GenreMap` accepts a third target verdict, `audience` (`audience: <name>`), and an
  `audiences:` header list.
- `ApplyCategories` resolves audience verdicts against active audience categories with the same
  evidence rule as genres; `ApplyAliases` adds aliases to audiences too.
- **Juvenile terms are weak evidence.** WorldCat's "Juvenile" covers about ages 0–15 and turns up on
  children's editions of classics (*Little Women*, *Animal Farm*) and on *Harry Potter*. Terms built
  on it ("Juvenile fiction", "Juvenile literature", "Juvenile works", "Juvenile materials", the
  `JUVENILE FICTION`/`JUVENILE NONFICTION` headings, and any subject phrase ending in "Juvenile
  fiction" or "Juvenile literature") carry `weak: true` on their Children's audience verdict. A weak
  term counts toward Children's only when the book already has the Children's audience, or when at
  least one matched record supports Children's through a non-weak term ("Children's stories",
  "Picture books for children", "Children's literature"). The retarget step sets the flag;
  `ApplyCategories` enforces it. Young Adult terms ("Young adult fiction", "Teen fiction") are not
  weak. The retarget step puts a weak Children's verdict first (as `audience:` with
  `weak: true`) whenever a Juvenile term's names include it, because `GenreMap` honours `weak` only
  on an audience primary. It fails when two decisions sharing a name would rewrite a term
  differently, or when a rewritten target is not in the headers. Nothing in WorldCat maps to Middle Grade.
  A term whose target is a `keep` or `rename` genre carrying `also:` gets those names in its own `also`
  (a union with any it has; never repeating the primary), and is not final while it lacks them.
- `retarget_worldcat` rewrites each term from the plan: a `keep`/`rename` genre takes the list
  name; `merge` takes its target (an audience target becomes an audience verdict); `audience`
  becomes an audience verdict; `subject` becomes a subject verdict with the resulting subject's
  name; `location` and `delete` become `drop` with reason `not_a_genre`, unless the decision has
  `worldcat:`, which wins (`Drama` → `Plays`). A term targeting a `split` genre follows that
  decision's `worldcat_terms`: the first name becomes its `genre:` (or `audience:`), any others go
  in a new optional `also:` list, and `ApplyCategories` counts the term as support for each
  (`Fantasy och science fiction` supports both Science Fiction and Fantasy; `History` supports only
  History). A term missing from `worldcat_terms` stops the retarget. It rewrites the `genres:` and `audiences:` header
  lists and leaves subject and drop verdicts alone. Running it twice gives the same file.
- `worldcat:apply_aliases` then runs against the cleaned list (§9 step 14, unchanged).

## 8. The old site

Genres are created in one place: the Goodreads import, `the-greatest-books/admin/app/models/book.rb`
around line 1627, `Category.create!(name: genre, import_source: :goodreads, category_type: :genre)`.
Change it to skip a genre it cannot find (`next if category.nil?`). Goodreads imports keep linking
existing genres. A separate small PR in that repository; Shane deploys it before the production
apply. Soft-deleted genres there stay soft-deleted, so nothing comes back through the sync.

## 9. Rollout

1. **PR 1, the code**: the commands, the audience type everywhere in §6, the `split` action and
   `extra_target_ids`, the WorldCat and legacy sync changes, docs. No plan file. It must work with
   zero audience categories (empty Audience group and tab are hidden) and with no plan file
   (`apply` says so and stops). Merge deploys it.
2. Dev, after PR 1: `draft`, Shane edits the list, `map`, `split_check`, Shane reviews with
   `report`, `retarget_worldcat`. Snapshot (`bin/snapshot-dev-db.sh --label pre-genre-cleanup`),
   then `apply` in dev and spot-check the filter modal, `/categories`, the global canon with
   `/excluding/children-s-books`, a saved search that used a deleted genre, a split book (*The Lord
   of the Rings* is Fantasy only), and Shane's recommendations page (user 1141).
   **PR 2, the files**: `genre_plan.yml`, `genre_split_assignments.csv` and the rewritten
   `genre_map.yml`, nothing else. Shane's review happens here. Merge deploys it.
3. Old site: the Goodreads change, deployed.
4. Production (Shane): the four-table dump from the category cleanup runbook, then
   `bin/rails categories:genres:apply`. If it stops on a genre missing from the plan, run `map`
   in dev for it, review, and ship the updated file.
5. Then launch-todo §9 steps 14–15 (WorldCat aliases and backfill) as already planned.

`docs/launch-todo.md` gains steps 3–4 as §9 steps 12–13, ahead of the WorldCat aliases (now step 14).

## 10. Testing

- Validator: one test per check, plus `committed_plan_test.rb`, which runs the Validator's
  database-free `structure_errors` against the committed `genre_plan.yml` and
  `genre_split_assignments.csv` (skipped while they are absent) and proves with temp files that a
  malformed plan fails. PR 2 is files only, so this test lands in PR 1.
- Decision builder: each action produces the decisions in §4, including the audience and subject
  rename-plus-retype pairs, merges into a renamed list entry, and both split modes.
- Applier `split`: every book ends on every target, existing links are not duplicated, sources are
  kept; merging and renaming modes; terminal for supersede and staleness.
- Legacy sync: a new legacy link to a split genre lands on all its targets, once.
- `apply`: end to end on fixtures, idempotent on a second run; deleted ids removed from saved
  search and recommendation criteria, and only those.
- AI tasks: stubbed responses; schema enums reject names off the lists; `map` resumes.
- `retarget_worldcat`: every action, the `worldcat:` override and the `weak` flag on Juvenile
  terms; a second run is a no-op.
- `ApplyCategories`/`ApplyAliases`: audience verdicts; a weak Juvenile term alone adds nothing;
  with a non-weak Children's term, or on a book already Children's, it counts.
- Every row of §6 that changes gets a test; the existing tests that pin genre-only behaviour
  (`filter_facets_query_test.rb`, `filter_title_test.rb`, `global_canon_params_test.rb`,
  `browse_query_test.rb`, `book_test.rb` indexing, `book_similar_test.rb`, recommendations) are
  extended, not loosened.
- E2E: the filter modal's Audience group and the `/categories` audience tab.

## 11. Out of scope

- Per-book genre fixes, including plays tagged only `Drama`: Spec B.
- Audience-aware scoring (keeping a children's book's similar books children's): later, tuned
  against user 1141.
- A time-period type; mood, pace and trope facets.
- Cleaning junk `alternative_names` left by past merges (`docs/todo.md`).
- Book records that are really series or box sets (*A Song of Ice and Fire* and its "5 Book Boxed
  Set"; about 400 titles match trilogy, box set, omnibus or complete series). They sit on lists and
  in rankings, so they need their own spec alongside the empty `Books::Series` model; added to
  `docs/todo.md`. This cleanup treats them like any other book.
