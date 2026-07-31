# Descriptions (d) — Public Read Paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flip the public games and music views from the `description` column to `primary_description`, so reads and writes both live in the `descriptions` table.

**Architecture:** A mechanical view rewire — `if @album.description.present?` becomes `if (description = @album.primary_description)`, with `description.content` in place of the column. One controller gains an `includes(:descriptions)` because its page renders a blurb per row at 100 rows a page. No new components, no schema change, no data run.

**Tech Stack:** Rails 8.1, Minitest + fixtures, `standardrb`.

**Spec:** `docs/superpowers/specs/2026-07-30-descriptions-d-read-paths-design.md` (decisions D-1, D-2, D-3).

**Depends on:** (c1) and (c2), already on this branch's ancestry (`descriptions-c` → `descriptions-c2`). This branch is `descriptions-d`, stacked on `descriptions-c2`.

---

## Global Constraints

- Run **every** Rails command from `web-app/`. Docs live at the project root in `docs/`, not `web-app/docs/`.
- Lint with `bundle exec standardrb` (`--fix` autocorrects). **Never** `bin/rubocop`. **Never** run brakeman.
- **The development database is not disposable.** The books data exists only in dev and takes hours to rebuild. Never run `db:drop`, `db:reset`, `db:schema:load`, `create_fixtures`, `data_migration:*`, or any bulk mutation. **This increment needs no migration and no data run.**
- **This increment changes where text comes from, not how it looks.** Keep every view's existing markup, classes and surrounding copy byte-identical apart from the two lines being swapped. A diff that also restyles is out of scope.
- **No N+1s.** Owner's instruction, 2026-07-30. `primary_description` reads an association, so any view rendering it **in a loop** needs `:descriptions` in its controller's `includes`. Two such sites exist and both are covered here: `music/albums/lists/show` (Task 2, paginates at 100) and the admin games series index (Task 3). Audited while planning — every other `.description` read in a loop belongs to `List`, `Category` or `RankingConfiguration`, which are authored config, stay on their columns, and are out of scope. If you find a third content-model site, preload it and say so.
- **`Descriptions::AttributionComponent` is NOT part of this increment** (D-1). Do not create it.
- **Do not touch the nine admin *show* pages** — (c2) already removed their legacy blocks and the descriptions panel renders there. Only the one admin *index-table* partial named below is in scope.
- **Do not touch any books public view.** They do not exist; the books public UI is a separate parked initiative.
- Controller tests assert **behaviour**. A description's `content` is data, not designer-changeable copy, so `assert_includes response.body, description.content` is in bounds. Asserting wrapper classes, the `prose` div, or surrounding wording is **not**.
- Every commit message ends with a blank line then `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.

### Facts verified against the codebase (do not re-derive)

- The four entity views are structurally identical. Current forms, with line numbers:
  - `app/views/games/games/show.html.erb:62-68` — `@game`
  - `app/views/music/albums/show.html.erb:58-64` — `@album`
  - `app/views/music/artists/show.html.erb:70-76` — `@artist`
  - `app/views/music/songs/show.html.erb:47-53` — `@song` (note: `mb-6` on the div, unlike the other three)
- `app/views/music/albums/lists/show.html.erb:159-165` renders the per-row blurb as
  `<p class="text-base-content/70 text-sm line-clamp-3"><%= album.description %></p>` inside an
  `<% if album.description.present? %>` guard.
- `Music::Albums::ListsController#show` (`app/controllers/music/albums/lists_controller.rb:32-38`) eager-loads
  `listable: [:artists, :categories, {primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}}}]`
  and paginates at `limit: 100`.
- `app/views/admin/games/series/_table.html.erb:29-31` still reads `series.description` — the one admin site (c2) did not cover.
- All five public controller tests exist: `test/controllers/{games/games,music/albums,music/artists,music/songs,music/albums/lists}_controller_test.rb`.
- `Describable#primary_description(kind: :summary, locale: "en")` returns a `Description` or `nil`, resolving `preferred` first, else `Descriptions::SourcePriority::ORDER`.
- `test/models/concerns/describable_test.rb` already uses `ActiveRecord::Assertions::QueryAssertions` via `require "active_record/testing/query_assertions"` — copy that setup for the query-count test.

### Fixture facts (checked — do not guess)

- `descriptions(:dark_side_ai)` → `music_albums(:dark_side_of_the_moon)`, `ai_generated`, `rank: preferred`.
- `descriptions(:botw_igdb)` → `games_games(:breath_of_the_wild)`, `igdb`, `rank: preferred`.
- **`Music::Artist` and `Music::Song` have NO description fixtures.** Tests for those two views must create a row inline.
- Music/games descriptions in real data are only `ai_generated`, `igdb` and `manual` — all with `license: nil` and `source_url: nil`.

---

## File Structure

| File | Responsibility |
|---|---|
| Modify `web-app/app/views/games/games/show.html.erb` | Read `primary_description` |
| Modify `web-app/app/views/music/albums/show.html.erb` | Same |
| Modify `web-app/app/views/music/artists/show.html.erb` | Same |
| Modify `web-app/app/views/music/songs/show.html.erb` | Same |
| Modify `web-app/app/views/music/albums/lists/show.html.erb` | Same, per row |
| Modify `web-app/app/controllers/music/albums/lists_controller.rb` | Add `:descriptions` to the preload |
| Modify `web-app/app/views/admin/games/series/_table.html.erb` | Same |
| Modify 4 × public controller tests | Assert the description text still reaches the body |
| Modify `web-app/test/controllers/music/albums/lists_controller_test.rb` | Blurb + query-count test |

---

### Task 1: Rewire the four entity show views

**Files:**
- Modify: `web-app/app/views/{games/games,music/albums,music/artists,music/songs}/show.html.erb`
- Test: `web-app/test/controllers/{games/games,music/albums,music/artists,music/songs}_controller_test.rb`

**Interfaces:**
- Consumes: `Describable#primary_description → Description | nil`.
- Produces: nothing new. Task 3's gate greps for leftover column reads.

- [ ] **Step 1: Write the failing tests**

Append to each of the four controller tests, inside the existing class. For `music/albums_controller_test.rb`:

```ruby
  test "show renders the album's primary description" do
    album = music_albums(:dark_side_of_the_moon)
    get music_album_path(album)

    assert_response :success
    assert_includes response.body, descriptions(:dark_side_ai).content
  end

  test "show renders successfully for an album with no description" do
    album = music_albums(:animals)
    assert_empty album.descriptions

    get music_album_path(album)
    assert_response :success
  end
```

For `games/games_controller_test.rb`, use `games_games(:breath_of_the_wild)` and `descriptions(:botw_igdb)`, plus a game with no descriptions for the second test.

For `music/artists_controller_test.rb` and `music/songs_controller_test.rb` there are **no** description fixtures, so create the row inline in the first test:

```ruby
  test "show renders the artist's primary description" do
    artist = music_artists(:pink_floyd)
    description = artist.descriptions.create!(
      kind: :summary, locale: "en", source: :ai_generated,
      content: "An English rock band formed in London."
    )

    get music_artist_path(artist)

    assert_response :success
    assert_includes response.body, description.content
  end
```

**Read each test file's existing path helper and host setup before writing** — these are public pages behind domain constraints, so each file already establishes the right host (e.g. `host! Rails.application.config.domains[:music]`). Match it; do not invent a new one. Confirm the fixture and route-helper names against the file rather than trusting the names above.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/games/games_controller_test.rb test/controllers/music/albums_controller_test.rb test/controllers/music/artists_controller_test.rb test/controllers/music/songs_controller_test.rb`

Expected: the four "renders the … primary description" tests FAIL — the views still read the `description` column, which is unrelated to the `Description` rows the tests create or reference. (The album and game cases may accidentally pass if that fixture's column happens to hold the same string — check the column value and, if so, note it and rely on the artist/song cases, which cannot false-pass.)

- [ ] **Step 3: Rewire the four views**

In each, replace the guard and the interpolation only. `music/albums/show.html.erb:58-64` becomes:

```erb
        <% if (description = @album.primary_description) %>
          <div class="prose max-w-none">
            <p class="text-base-content/70">
              <%= description.content %>
            </p>
          </div>
        <% end %>
```

Apply the same two-line change to the other three, substituting `@game`, `@artist`, `@song`. **Preserve each file's own surrounding markup exactly** — `music/songs/show.html.erb` has `mb-6` on its wrapper div and different indentation; do not normalise them to match each other.

- [ ] **Step 4: Run the tests to verify they pass**

Run the same command as Step 2.

Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/views/ test/controllers/
git add web-app/app/views/games/games/show.html.erb web-app/app/views/music/albums/show.html.erb web-app/app/views/music/artists/show.html.erb web-app/app/views/music/songs/show.html.erb web-app/test/controllers/
git commit -m "Read primary_description on the four entity show pages

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Rewire the list blurb and preload it

The only place in this increment where the rewire has a performance consequence: this page renders a blurb per album and paginates at 100, so an unpreloaded `primary_description` is 100 extra queries.

**Files:**
- Modify: `web-app/app/views/music/albums/lists/show.html.erb`
- Modify: `web-app/app/controllers/music/albums/lists_controller.rb`
- Test: `web-app/test/controllers/music/albums/lists_controller_test.rb`

**Interfaces:**
- Consumes: `Describable#primary_description`, and the `has_many :descriptions` association for preloading.
- Produces: nothing new.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/music/albums/lists_controller_test.rb`. Read the file first for its existing setup — it needs a list, a ranking configuration and the music host, all of which the existing tests already establish; reuse that setup rather than building your own.

```ruby
  test "show renders each album's primary description" do
    album = music_albums(:dark_side_of_the_moon)
    # ... position the album on @list using the file's existing helper/fixtures ...

    get music_albums_list_path(@list)

    assert_response :success
    assert_includes response.body, descriptions(:dark_side_ai).content
  end

  test "show preloads descriptions rather than querying per row" do
    get music_albums_list_path(@list)
    assert_response :success

    assert_queries_count(0) do
      @list.list_items.first.listable.primary_description
    end
  end
```

The query-count test needs `require "active_record/testing/query_assertions"` at the top of the file and `include ActiveRecord::Assertions::QueryAssertions` in the class — copy the setup from `test/models/concerns/describable_test.rb`.

**That second test as written will not work unless the controller's preloaded collection is what you assert against** — `@list.list_items` in the test body issues a fresh query with no preload. Restructure it to exercise the controller's own eager-loaded scope: build the same `includes(...)` the controller uses, load it, then assert `primary_description` on a member costs 0 queries. Get it genuinely failing before the fix, or it proves nothing.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/music/albums/lists_controller_test.rb`

Expected: the blurb test fails (view still reads the column) and the query-count test fails (no preload).

- [ ] **Step 3: Add the preload**

In `app/controllers/music/albums/lists_controller.rb`, add `:descriptions` to the `listable:` array:

```ruby
    list_items_query = @list.list_items.includes(
      listable: [
        :artists,
        :categories,
        :descriptions,
        {primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}}}
      ]
    ).order(:position)
```

- [ ] **Step 4: Rewire the blurb**

`app/views/music/albums/lists/show.html.erb:159-165` becomes:

```erb
                  <!-- Description -->
                  <% if (description = album.primary_description) %>
                    <div>
                      <p class="text-base-content/70 text-sm line-clamp-3">
                        <%= description.content %>
                      </p>
                    </div>
                  <% end %>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/music/albums/lists_controller_test.rb`

Expected: PASS.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/controllers/music/ app/views/music/ test/controllers/music/
git add web-app/app/controllers/music/albums/lists_controller.rb web-app/app/views/music/albums/lists/show.html.erb web-app/test/controllers/music/albums/lists_controller_test.rb
git commit -m "Read primary_description in the album list blurbs, preloaded

The page paginates at 100 rows, so the association is eager-loaded alongside
artists and categories to keep primary_description from firing per row.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The last admin site, and the gate

`admin/games/series/_table.html.erb` reads `series.description`. It is an **index-table** partial, not a show page, which is why increment (c2) — which only cleared the nine show pages — did not cover it. It is also the site the parent spec's "nine admin views" count missed.

**Files:**
- Modify: `web-app/app/views/admin/games/series/_table.html.erb`

**Interfaces:** none.

- [ ] **Step 1: Rewire it**

`app/views/admin/games/series/_table.html.erb:29-31` currently guards on `series.description.present?` and renders `truncate(series.description, length: 80)`. Rewire to `series.primary_description`, keeping the truncation and the surrounding cell markup:

```erb
              <% if (description = series.primary_description) %>
                ...
                  <%= truncate(description.content, length: 80) %>
```

Read the surrounding lines first and preserve them exactly.

- [ ] **Step 2: Preload descriptions on the index**

Verified while planning: `load_series_for_index` (`app/controllers/admin/games/series_controller.rb:66-67`) starts from `Games::Series.all`, and this partial renders a description per row — so without a preload that is one query per series. Dev holds 15 rows, which is small, but the fix is free and N+1s are not to be left in place.

Add `:descriptions` to that scope:

```ruby
    @series_collection = Games::Series.includes(:descriptions)
```

Keep the subsequent search/sort chaining exactly as it is — `includes` composes with them.

Pin it with a query-count test in `test/controllers/admin/games/series_controller_test.rb`, structured to exercise the controller's own scope (see Task 2 Step 1's warning about assertions that re-query and therefore prove nothing).

- [ ] **Step 3: Run the admin tests**

Run: `bin/rails test test/controllers/admin/`

Expected: PASS.

- [ ] **Step 4: Full gate**

```bash
cd web-app && bundle exec standardrb && bin/rails test
```

Expected: `standardrb` clean; suite green (4,996 runs as of c2, plus this increment's tests).

**Do not run `test:system`** — it is red on `main` for an unrelated missing gem (`rack_session_access`) and is not a usable gate.

- [ ] **Step 5: Confirm no public view still reads the column**

```bash
cd web-app && grep -rn '\.description\b' app/views --include='*.erb' \
  | grep -vE 'list\.description|@list\.description|category\.description|@category\.description|penalt|ranking_config|primary_description'
```

Expected: **no output.** Any hit is a content-model description read that survived. `List` and `Category` descriptions are authored config and legitimately remain — that is what the filter excludes.

- [ ] **Step 6: Commit**

```bash
git add web-app/app/views/admin/games/series/_table.html.erb web-app/app/controllers/admin/games/
git commit -m "Read primary_description in the games series admin table

The one admin site increment c2 did not cover -- an index-table partial
rather than a show page.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage.** D-1 (no `AttributionComponent`) → stated in Global Constraints as a prohibition rather than an omission, so an implementer cannot helpfully add it. D-2 (only the list page preloads) → Task 2 Step 3, with Task 3 Step 2 asking the implementer to check whether the admin index needs the same treatment rather than assuming. D-3 (keep guards and markup) → Global Constraints plus per-task warnings about `music/songs`' differing wrapper and the four files' differing indentation. The spec's four entity views → Task 1; the list blurb + N+1 → Task 2; the admin table partial → Task 3. Out of scope per the spec and absent here: the nine admin show pages, books public views, dropping the columns.

**2. Placeholder scan.** Task 2 Step 1's blurb test contains an explicit `# ... position the album on @list ...` gap. That is deliberate and flagged in prose: the file's existing list/ranking-configuration setup was not read while planning, and inventing fixture wiring that does not match would be worse than telling the implementer to reuse what is there. The same step also warns that the query-count assertion as drafted will not fail correctly unless restructured, and says why — a plan that shipped that assertion silently would have produced a test that proves nothing.

**3. Type consistency.** `primary_description` returns `Description | nil` throughout; every rewire assigns it to a local in the guard and calls `.content`. The controller preload uses `:descriptions` (the association name from `Describable`), not `:description`. Fixture accessors are `descriptions(:dark_side_ai)` and `descriptions(:botw_igdb)`; artist and song rows are created inline because no fixture exists.
