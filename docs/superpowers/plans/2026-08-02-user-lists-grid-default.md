# User Lists: Grid as the Default View — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make user lists open in grid view by default in every domain, and make the books My Lists grid render in the same container as every other books grid.

**Architecture:** `view_mode` is a persisted integer enum on the shared `UserList` STI base. Task 1 renames member 0 from `default_view` to `list_view` without changing behavior. Task 2 flips the enum/column default to `grid_view` and backfills the 282,687 rows that hold the old default only because the legacy migration mapped legacy `NULL` onto it. Tasks 4–6 pull the books grid container into one constant, teach the shared `UserLists::Show::ItemComponent` which container each listable wants, and give books grid cards their `#N` badge.

**Tech Stack:** Rails 8.1, Minitest + fixtures + Mocha, ViewComponent, Tailwind CSS 4 + DaisyUI 5, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-02-user-lists-grid-default-design.md`

## Global Constraints

- Run **all** Rails commands from `web-app/`. Docs live in `docs/` at the **project root**, not `web-app/docs/`.
- Lint with `bundle exec standardrb` (NOT `bin/rubocop`). Do not run brakeman.
- **No code comments unless the plan shows one.** Where this plan includes a comment in a code block, it is load-bearing — write it verbatim.
- Rails 8 enum syntax: `enum :view_mode, {...}` with a colon prefix.
- Controller tests assert **behavior** (status codes, persisted state, query counts) — never HTML, CSS, or copy.
- **The development database is not disposable.** The books data exists only in dev and takes hours to rebuild. Task 2 mutates ~282,687 dev rows; its first step is a snapshot. Never run `ActiveRecord::FixtureSet.create_fixtures`, `db:drop`, `db:reset`, or `db:schema:load` against development.
- Working directory for this plan: `/home/shane/dev/the-greatest/.claude/worktrees/user-lists-grid-default`, branch `worktree-user-lists-grid-default`.
- Baseline before starting: **5386 runs, 14270 assertions, 0 failures, 0 errors, 0 skips.**

---

## File Structure

**Modified:**

| File | Responsibility after this plan |
|---|---|
| `web-app/app/models/user_list.rb` | Enum member `list_view` at 0, default `grid_view`; owns `VIEW_MODE_LABELS` (switcher order + copy) |
| `web-app/db/migrate/<ts>_default_user_lists_to_grid_view.rb` | Column default 0 → 2 and the one-way backfill |
| `web-app/app/lib/services/books_migration/user_list_migrator.rb` | Legacy `NULL` view_mode → `grid_view` |
| `web-app/app/components/books/card_component.rb` | Owns `GRID_CONTAINER_CLASS`, the one definition of the books grid |
| `web-app/app/components/user_lists/show/item_component.rb` | Adds `grid_container_class` dispatch and an `index:` kwarg; passes `rank:` for books |
| `web-app/app/views/my_lists/show.html.erb` | Reads `VIEW_MODE_LABELS` and `grid_container_class`; passes display index |
| `web-app/app/views/books/{ranked_items/index,lists/show,authors/show,authors/all_books}.html.erb` | Reference the shared constant instead of an inline literal |
| `web-app/e2e/tests/books/account/my-lists.spec.ts` | Switcher spec clicks **List**, since Grid is now the landing state |
| `docs/features/user-lists.md` | View-mode section reflects the new name, default, and order |
| `docs/specs/user-lists-02f-list-management-and-editing.md` | One `default_view` reference |

**Created:** the migration only. No new classes, no new components, no new test files.

**Deliberately untouched:** `docs/old_site/user-lists-feature.md` and everything under `docs/specs/completed/`. Those record the legacy app and shipped history; the old site's `default_view: nil` is the evidence for Task 3.

---

## Task 1: Rename the enum member `default_view` → `list_view`

Pure rename plus the switcher's label/order source. Integer values do not move, so no data changes and no migration. The default is still `default_view`'s integer (0) at the end of this task — Task 2 flips it.

**Files:**
- Modify: `web-app/app/models/user_list.rb:54`
- Modify: `web-app/app/views/my_lists/show.html.erb:3,49`
- Modify: `web-app/test/models/user_list_test.rb`
- Modify: `web-app/test/controllers/my_lists_controller_test.rb`
- Modify: `web-app/test/components/user_lists/show/item_component_test.rb`
- Modify: `web-app/test/lib/services/books_migration/user_list_migrator_test.rb:47`
- Modify: `docs/features/user-lists.md:242`
- Modify: `docs/specs/user-lists-02f-list-management-and-editing.md:136`

**Interfaces:**
- Produces: `UserList` enum members `list_view` (0), `table_view` (1), `grid_view` (2); predicate `#list_view?`; constant `UserList::VIEW_MODE_LABELS` — a frozen `Hash[String => String]` in switcher order, `{"grid_view" => "Grid", "list_view" => "List", "table_view" => "Table"}`.

- [ ] **Step 1: Rewrite the tests to the new name (these are the failing tests)**

Run the sweep from `web-app/`:

```bash
sed -i 's/default_view/list_view/g' \
  test/models/user_list_test.rb \
  test/controllers/my_lists_controller_test.rb \
  test/components/user_lists/show/item_component_test.rb \
  test/lib/services/books_migration/user_list_migrator_test.rb
```

Then fix the two test *names* that now read badly, which `sed` cannot judge:

In `test/models/user_list_test.rb`, the two renamed tests should read:

```ruby
  test "view_mode defaults to list_view on new records" do
    list = Music::Albums::UserList.new(user: @user, name: "Fresh", list_type: :custom)
    assert list.list_view?
  end

  test "view_mode defaults to list_view after save" do
    list = Music::Albums::UserList.create!(user: users(:editor_user), name: "Persisted", list_type: :favorites)
    assert list.reload.list_view?
  end
```

In `test/lib/services/books_migration/user_list_migrator_test.rb`, the test name `"remaps view_mode, treating NULL as the default member"` still describes the current behavior correctly — leave it; Task 3 rewrites it.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/models/user_list_test.rb test/controllers/my_lists_controller_test.rb test/components/user_lists/show/item_component_test.rb test/lib/services/books_migration/user_list_migrator_test.rb
```

Expected: FAIL. `NoMethodError: undefined method 'list_view?'` from the model tests, and `ArgumentError: 'list_view' is not a valid view_mode` from the controller tests that pass it as a param or assign it.

- [ ] **Step 3: Rename the enum member**

`app/models/user_list.rb:54` — replace the enum line with:

```ruby
  enum :view_mode, {list_view: 0, table_view: 1, grid_view: 2}, default: :list_view
```

- [ ] **Step 4: Add `VIEW_MODE_LABELS` to the model**

Insert directly below the enum line:

```ruby
  # Switcher order and copy. Declared here rather than in the view so the
  # default view mode can read first without reordering the enum's integers.
  VIEW_MODE_LABELS = {
    "grid_view" => "Grid",
    "list_view" => "List",
    "table_view" => "Table"
  }.freeze
```

- [ ] **Step 5: Point the view at `VIEW_MODE_LABELS`**

In `app/views/my_lists/show.html.erb`, delete line 3 entirely:

```erb
  view_mode_labels = {"default_view" => "List", "table_view" => "Table", "grid_view" => "Grid"}
```

Then replace the switcher loop (lines 49–53) with:

```erb
            <% UserList::VIEW_MODE_LABELS.each do |mode, label| %>
              <%= link_to label,
                    my_list_path(@list, view_mode: mode, sort: ranking_sort),
                    class: "join-item btn btn-sm #{(@view_mode == mode) ? "btn-primary" : "btn-outline"}" %>
            <% end %>
```

`MyListsController` needs no change: `params[:view_mode].presence_in(UserList.view_modes.keys)` and `UserList.view_modes.key?(requested)` both resolve against the renamed member.

- [ ] **Step 6: Run the full suite**

```bash
bin/rails test
```

Expected: PASS, 5386 runs, 0 failures. If anything still references `default_view`, this is where it surfaces.

- [ ] **Step 7: Confirm no stray references remain in app or test code**

```bash
grep -rn "default_view" app test
```

Expected: no output.

- [ ] **Step 8: Update the two live docs**

In `docs/features/user-lists.md:242`, change the bullet's leading term:

```markdown
- **`list_view`** ("List") — a compact, full-width row per item: number + title-by-author heading, a small cover thumbnail, the item's **description**, a year/completed line, and the Add-to-list widget. Only for listables with covers/descriptions (albums, games, books).
```

In `docs/specs/user-lists-02f-list-management-and-editing.md:136`, change `default_view` to `list_view` in that one sentence. Leave the rest of the line alone.

Do **not** touch `docs/old_site/user-lists-feature.md` or `docs/specs/completed/`.

- [ ] **Step 9: Lint**

```bash
bundle exec standardrb
```

Expected: no offenses.

- [ ] **Step 10: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/user-lists-grid-default
git add web-app/app/models/user_list.rb web-app/app/views/my_lists/show.html.erb web-app/test docs/features/user-lists.md docs/specs/user-lists-02f-list-management-and-editing.md
git commit -m "Rename the default_view user list mode to list_view

The member is about to stop being the default, and a mode named
default_view that is not the default is a trap. Integer values are
unchanged. Switcher order and copy move to UserList::VIEW_MODE_LABELS
so the default can read first without reordering the enum.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Flip the default to `grid_view`

Changes the enum default, the column default, and the 282,687 existing rows. Also repairs the tests that were silently relying on fixtures inheriting the list-view default.

**Files:**
- Create: `web-app/db/migrate/<timestamp>_default_user_lists_to_grid_view.rb`
- Modify: `web-app/app/models/user_list.rb` (enum default)
- Modify: `web-app/db/schema.rb` (regenerated by `db:migrate`, do not hand-edit)
- Modify: `web-app/test/models/user_list_test.rb`
- Modify: `web-app/test/controllers/my_lists_controller_test.rb`
- Modify: `web-app/e2e/tests/books/account/my-lists.spec.ts:27-35`
- Modify: `docs/features/user-lists.md`

**Interfaces:**
- Consumes: `list_view` / `VIEW_MODE_LABELS` from Task 1.
- Produces: `UserList.new.view_mode == "grid_view"`; `user_lists.view_mode` column default `2`; zero rows remaining at `0` except any created after the migration by an explicit choice.

- [ ] **Step 1: Snapshot the development database before anything else**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/user-lists-grid-default/web-app
bin/snapshot-dev-db.sh --label pre-grid-default
```

Expected: a snapshot file is written. Restore with `bin/snapshot-dev-db.sh --restore` if the migration goes wrong. Do not proceed without this — the books data exists only in dev.

- [ ] **Step 2: Write the failing tests**

In `test/models/user_list_test.rb`, replace the two default tests from Task 1 with:

```ruby
  test "view_mode defaults to grid_view on new records" do
    list = Music::Albums::UserList.new(user: @user, name: "Fresh", list_type: :custom)
    assert list.grid_view?
  end

  test "view_mode defaults to grid_view after save" do
    list = Music::Albums::UserList.create!(user: users(:editor_user), name: "Persisted", list_type: :favorites)
    assert list.reload.grid_view?
  end

  test "list_view is still reachable and maps to zero" do
    @list.update!(view_mode: :list_view)
    assert @list.reload.list_view?
    assert_equal 0, @list.reload.view_mode_before_type_cast
  end
```

- [ ] **Step 3: Run them to verify they fail**

```bash
bin/rails test test/models/user_list_test.rb
```

Expected: FAIL — the two default tests fail because a new record is still `list_view`. The third test passes already; that is fine, it is a guard for the rename, not a new behavior.

- [ ] **Step 4: Change the enum default**

`app/models/user_list.rb` — the enum line becomes:

```ruby
  enum :view_mode, {list_view: 0, table_view: 1, grid_view: 2}, default: :grid_view
```

- [ ] **Step 5: Generate the migration**

```bash
bin/rails generate migration DefaultUserListsToGridView
```

Use the generator; do not hand-create the file.

- [ ] **Step 6: Write the migration body**

Replace the generated file's contents with (keeping the generated class name and Rails version):

```ruby
class DefaultUserListsToGridView < ActiveRecord::Migration[8.1]
  # The backfill is one-way on purpose. Legacy NULL (the old site's "user never
  # picked one") was mapped onto view_mode 0, so every row still sitting at 0 is
  # an unset preference rather than a choice. Once they move to 2 there is no way
  # to tell them apart from the 259 lists that genuinely chose grid, so `down`
  # restores the column default only.
  def up
    change_column_default :user_lists, :view_mode, from: 0, to: 2
    execute "UPDATE user_lists SET view_mode = 2 WHERE view_mode = 0"
  end

  def down
    change_column_default :user_lists, :view_mode, from: 2, to: 0
  end
end
```

- [ ] **Step 7: Run the migration against development**

```bash
bin/rails db:migrate
```

Expected: succeeds in seconds, and `db/schema.rb` now shows `t.integer "view_mode", default: 2, null: false` with a bumped version line.

- [ ] **Step 8: Verify the backfill landed and left explicit choices alone**

```bash
bin/rails runner 'puts UserList.group(:view_mode).count.inspect'
```

Expected: `{"table_view" => 422, "grid_view" => 282946}` — zero rows at `list_view`, and `table_view` still exactly 422. If `table_view` changed, restore the snapshot and stop.

- [ ] **Step 9: Run the model tests to verify they now pass**

```bash
bin/rails db:test:prepare && bin/rails test test/models/user_list_test.rb
```

Expected: PASS.

- [ ] **Step 10: Run the full suite to surface the fixture fallout**

```bash
bin/rails test
```

Expected: FAIL, in `test/controllers/my_lists_controller_test.rb`. Fixtures do not set `view_mode`, so they now load as `grid_view`, and any test that fetched a list with no `view_mode` param while expecting list-view markup no longer gets it. The certain casualty is `"show renders each album's primary description in list_view"`.

Two related tests do **not** fail but have gone vacuous, and Step 11 repairs them anyway: the descriptions-preload test still sees one query because the preload lives in `listable_display_includes` regardless of view mode, and the persistence test switches *to* `grid_view`, which is now where the list already is, so `persist_view_mode` returns early and the assertion passes without proving anything.

- [ ] **Step 11: Make the affected controller tests state the mode they are testing**

Fix any failure this step did not predict the same way — make the test name the mode it exercises and pass `view_mode:` explicitly, rather than changing what the test asserts.

In `test/controllers/my_lists_controller_test.rb`:

```ruby
  test "switching view_mode persists it on the list and re-renders" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_favorites, view_mode: "list_view")
    assert_response :success
    assert_equal "list_view", @albums_favorites.reload.view_mode

    # subsequent visit with no param renders the persisted mode
    get my_list_path(@albums_favorites)
    assert_equal "list_view", @albums_favorites.reload.view_mode
  end

  test "show renders each album's primary description in list_view" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_favorites, view_mode: "list_view")
    assert_response :success
    assert_includes response.body, descriptions(:dark_side_ai).content
  end

  test "show preloads descriptions rather than querying per row in list_view" do
    sign_in_as(@user, stub_auth: true)

    assert_queries_match(/FROM "descriptions"/, count: 1) do
      get my_list_path(@albums_favorites, view_mode: "list_view")
    end

    assert_response :success
  end
```

The first one previously switched *to* `grid_view`, which is now the default and would pass whether or not persistence worked. Switching to `list_view` restores what it was meant to prove.

- [ ] **Step 12: Add a test for the new landing state**

Add to `test/controllers/my_lists_controller_test.rb`, next to the other view_mode tests:

```ruby
  test "a list that has never had a view mode set lands on grid" do
    sign_in_as(@user, stub_auth: true)
    assert_equal "grid_view", @albums_favorites.view_mode

    get my_list_path(@albums_favorites)
    assert_response :success
    assert_equal "grid_view", @albums_favorites.reload.view_mode
  end
```

- [ ] **Step 13: Run the full suite again**

```bash
bin/rails test
```

Expected: PASS, 0 failures. Run count is 5388 — baseline 5386, plus one from Step 2 (two tests became three) and one from Step 12.

- [ ] **Step 14: Fix the Playwright switcher spec**

`e2e/tests/books/account/my-lists.spec.ts` — the switcher test currently clicks **Grid**, which is now where the page already is, so it would pass without the switcher working at all. Replace the test with:

```typescript
  test('a list page offers all three view modes and switches between them', async ({ page }) => {
    await page.goto('/my/lists');
    await page.getByTestId('my-lists-dashboard').getByText('My Favorite Books').click();

    const toolbar = page.getByTestId('list-toolbar');
    await expect(toolbar.getByRole('link', { name: 'Grid' })).toBeVisible();
    await expect(toolbar.getByRole('link', { name: 'Table' })).toBeVisible();
    await toolbar.getByRole('link', { name: 'List' }).click();

    await expect(page).toHaveURL(/view_mode=list_view/);
  });
```

The suite is run in Task 7, not here — it needs a local dev server.

- [ ] **Step 15: Update the docs**

In `docs/features/user-lists.md`, in the "Show (`show`)" section:

- Reorder the three view-mode bullets to **`grid_view`**, **`list_view`**, **`table_view`**, matching the switcher.
- On the `grid_view` bullet, append: `This is the default for new lists.`
- In the paragraph beginning "Switching `?view_mode=` persists the choice", append: `New lists default to `grid_view`; the 2026-08-02 migration moved every list still holding the old list-view default onto it.`

- [ ] **Step 16: Lint**

```bash
bundle exec standardrb
```

Expected: no offenses.

- [ ] **Step 17: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/user-lists-grid-default
git add web-app/app/models/user_list.rb web-app/db web-app/test web-app/e2e docs/features/user-lists.md
git commit -m "Default user lists to grid view

Flips the enum and column default and backfills the 282,687 lists still
holding view_mode 0, which they hold because the legacy migration mapped
legacy NULL (never chose) onto it, not because anyone picked list view.
The 259 grid and 422 table choices are untouched.

Fixtures inherit the new default, so three controller tests that relied
on the implicit list-view landing now say which mode they are testing.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Point the legacy books migrator at the new default

`Services::BooksMigration::UserListMigrator` is idempotent on `id` and maps legacy `NULL` → `0`. Production has never run the books migration, so all 282,928 legacy books lists still have to pass through it. Left alone, that run upserts every one of them onto `list_view` and silently undoes Task 2.

**Files:**
- Modify: `web-app/app/lib/services/books_migration/user_list_migrator.rb:12-15,19`
- Modify: `web-app/test/lib/services/books_migration/user_list_migrator_test.rb`

**Interfaces:**
- Consumes: `grid_view` as the site default, from Task 2.
- Produces: `VIEW_MODE_MAP == {nil => 2, 1 => 1, 2 => 2}`.

- [ ] **Step 1: Write the failing tests**

In `test/lib/services/books_migration/user_list_migrator_test.rb`, replace the view_mode test with:

```ruby
      test "remaps view_mode, treating legacy NULL as the site default" do
        result = run_migrator([
          legacy_row("id" => 300020, "list_type" => 0, "view_mode" => nil),
          legacy_row("id" => 300021, "list_type" => 1, "view_mode" => 1),
          legacy_row("id" => 300022, "list_type" => 2, "view_mode" => 2)
        ])

        assert result[:success], result[:error]
        assert_equal "grid_view", ::UserList.find(300020).view_mode
        assert_equal "table_view", ::UserList.find(300021).view_mode
        assert_equal "grid_view", ::UserList.find(300022).view_mode
      end
```

In the same file, the "migrates a legacy list" test asserts `assert list.list_view?` (renamed in Task 1) on a row whose `view_mode` is `NULL`. Change that line to:

```ruby
        assert list.grid_view?
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/lib/services/books_migration/user_list_migrator_test.rb
```

Expected: FAIL — two failures, both `Expected: "grid_view" / Actual: "list_view"`.

- [ ] **Step 3: Change the map**

`app/lib/services/books_migration/user_list_migrator.rb:19`:

```ruby
      VIEW_MODE_MAP = {nil => 2, 1 => 1, 2 => 2}.freeze
```

- [ ] **Step 4: Correct the class comment that documents the old mapping**

In the same file, the comment block above the class currently reads, in part, `view_mode's legacy default member is NULL, not 0.` Replace that sentence with:

```ruby
    # view_mode's legacy default member is NULL, not 0; it means "user never picked one",
    # so it maps to the new site default (grid_view), not to the integer 0 slot.
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bin/rails test test/lib/services/books_migration/user_list_migrator_test.rb
```

Expected: PASS.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb
cd /home/shane/dev/the-greatest/.claude/worktrees/user-lists-grid-default
git add web-app/app/lib/services/books_migration/user_list_migrator.rb web-app/test/lib/services/books_migration/user_list_migrator_test.rb
git commit -m "Map legacy NULL view_mode to the new grid default

UserListMigrator is idempotent on id and production has never run the
books migration, so leaving legacy NULL pointed at 0 would upsert all
282,928 books lists back onto list view and undo the backfill.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Extract the books grid container into one constant

Pure refactor: four books views hold the identical class string, and My Lists is about to need a fifth copy. No behavior changes, so the existing suite plus a byte-identical render check is the guard.

**Files:**
- Modify: `web-app/app/components/books/card_component.rb`
- Modify: `web-app/app/views/books/ranked_items/index.html.erb:22`
- Modify: `web-app/app/views/books/lists/show.html.erb:36`
- Modify: `web-app/app/views/books/authors/show.html.erb:24`
- Modify: `web-app/app/views/books/authors/all_books.html.erb:23`

**Interfaces:**
- Produces: `Books::CardComponent::GRID_CONTAINER_CLASS` — a frozen `String` whose value is exactly `"grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-6"`. Task 5 consumes it.

- [ ] **Step 1: Add the constant**

`app/components/books/card_component.rb` — insert directly below `EAGER_IMAGE_COUNT = 6`:

```ruby
  # The grid this card is designed for. Every books grid references it, so My
  # Lists cannot drift away from the homepage the way it did before.
  GRID_CONTAINER_CLASS = "grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 " \
    "lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-6"
```

Keep each class token whole within its line. Tailwind's scanner is a regex over raw text and will not reassemble a token split across the `\` continuation. `.rb` files under `app/components/` *are* scanned — all five stylesheets declare `@source ".../app/components/**/*"` with no extension filter — so the classes survive the move out of ERB.

- [ ] **Step 2: Replace the literal in all four views**

Each of the four files contains this exact line (at `ranked_items/index.html.erb:22`, `lists/show.html.erb:36`, `authors/show.html.erb:24`, `authors/all_books.html.erb:23`), with differing leading indentation:

```erb
<div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-6">
```

Replace each with, preserving that file's indentation:

```erb
<div class="<%= Books::CardComponent::GRID_CONTAINER_CLASS %>">
```

- [ ] **Step 3: Verify no inline copy survives**

```bash
grep -rn "xl:grid-cols-6" app/views app/components
```

Expected: exactly one hit — the constant in `app/components/books/card_component.rb`.

- [ ] **Step 4: Verify the rendered markup is unchanged**

```bash
bin/rails test test/controllers/books test/components/books
```

Expected: PASS. Then confirm the class string actually reaches the page:

```bash
bin/rails runner 'puts Books::CardComponent::GRID_CONTAINER_CLASS'
```

Expected: `grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-6` — one line, single spaces, no double space at the seam.

- [ ] **Step 5: Rebuild CSS and confirm the classes are still emitted**

`node_modules/` is present in this worktree, so no `yarn install` is needed.

```bash
yarn build:all
grep -c "grid-cols-6" app/assets/builds/books.css
```

Expected: at least `1`. A `0` means Tailwind stopped seeing the classes after they moved out of ERB, and the grid would silently collapse to one column — do not proceed past this. `app/assets/builds/` is generated output; check `git status` and do not stage it unless it was already tracked.

- [ ] **Step 6: Run the full suite, lint, and commit**

```bash
bin/rails test
bundle exec standardrb
```

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/user-lists-grid-default
git add web-app/app/components/books/card_component.rb web-app/app/views/books
git commit -m "Give the books grid container one definition

Four views held the same class string and My Lists was about to add a
fifth. Books::CardComponent::GRID_CONTAINER_CLASS is now the only copy.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

Do not commit `app/assets/builds/` unless it was already tracked and changed; check `git status` before adding.

---

## Task 5: Teach `ItemComponent` which grid container each listable wants

**Files:**
- Modify: `web-app/app/components/user_lists/show/item_component.rb`
- Modify: `web-app/app/views/my_lists/show.html.erb:106`
- Modify: `web-app/test/components/user_lists/show/item_component_test.rb`

**Interfaces:**
- Consumes: `Books::CardComponent::GRID_CONTAINER_CLASS` from Task 4.
- Produces: `UserLists::Show::ItemComponent.grid_container_class(listable_class)` — takes a `String` or `Class`, returns a `String`. `"Books::Book"` returns the books constant; everything else returns `UserLists::Show::ItemComponent::DEFAULT_GRID_CONTAINER_CLASS`.

- [ ] **Step 1: Write the failing test**

Add to `test/components/user_lists/show/item_component_test.rb`, after the `card_capable?` tests:

```ruby
  test "grid_container_class gives books the dense books grid" do
    assert_equal Books::CardComponent::GRID_CONTAINER_CLASS,
      Component.grid_container_class("Books::Book")
    assert_equal Books::CardComponent::GRID_CONTAINER_CLASS,
      Component.grid_container_class(Books::Book)
  end

  test "grid_container_class gives every other listable the shared four-column grid" do
    assert_equal Component::DEFAULT_GRID_CONTAINER_CLASS,
      Component.grid_container_class("Music::Album")
    assert_equal Component::DEFAULT_GRID_CONTAINER_CLASS,
      Component.grid_container_class("Games::Game")
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/components/user_lists/show/item_component_test.rb
```

Expected: FAIL with `NoMethodError: undefined method 'grid_container_class'`.

- [ ] **Step 3: Implement it**

`app/components/user_lists/show/item_component.rb` — add below the `CARD_LISTABLES` constant:

```ruby
  DEFAULT_GRID_CONTAINER_CLASS =
    "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6"
```

And add below `self.table_layout?`:

```ruby
  # Books covers are 2:3 and tile far denser than square album art, so books get
  # their own grid shape — the same one the homepage and /lists/:id use. Every
  # other listable keeps the four-column grid, which already matches the music
  # and games ranked grids. Called once per page: lists are homogeneous.
  def self.grid_container_class(listable_class)
    if listable_class.to_s == "Books::Book"
      Books::CardComponent::GRID_CONTAINER_CLASS
    else
      DEFAULT_GRID_CONTAINER_CLASS
    end
  end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/components/user_lists/show/item_component_test.rb
```

Expected: PASS.

- [ ] **Step 5: Wire it into the show view**

`app/views/my_lists/show.html.erb:106` — replace:

```erb
        <% container_class = (@view_mode == "grid_view") ? "grid gap-6 grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4" : "space-y-6" %>
```

with:

```erb
        <% container_class = (@view_mode == "grid_view") ? UserLists::Show::ItemComponent.grid_container_class(@list.class.listable_class) : "space-y-6" %>
```

Note the old literal wrote `grid gap-6 grid-cols-1 …` while `DEFAULT_GRID_CONTAINER_CLASS` writes `grid grid-cols-1 … gap-6`. Same classes, different order — no visual change.

- [ ] **Step 6: Run the suite, lint, and commit**

```bash
bin/rails test
bundle exec standardrb
```

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/user-lists-grid-default
git add web-app/app/components/user_lists/show/item_component.rb web-app/app/views/my_lists/show.html.erb web-app/test/components/user_lists/show/item_component_test.rb
git commit -m "Render the books My Lists grid in the real books grid

My Lists showed one giant 2:3 cover per row on mobile and four at xl,
against two and six everywhere else on the books site. The cards were
always the same component; only the container was wrong.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Rank badge on grid cards, and a real cover-loading index

Two changes to the same method, so one task. Books grid cards gain the `#N` badge that `/lists/:id` cards carry, and `index` stops being derived from `position` — under `?sort=ranking`, position is the item's stored slot, not its place on the page, so the eager-load window was landing on six arbitrary covers.

**Files:**
- Modify: `web-app/app/components/user_lists/show/item_component.rb`
- Modify: `web-app/app/views/my_lists/show.html.erb:99-101,108-110`
- Modify: `web-app/test/components/user_lists/show/item_component_test.rb`

**Interfaces:**
- Consumes: `Books::CardComponent.new(book:, rank: nil, index: nil)` — already its signature.
- Produces: `UserLists::Show::ItemComponent.new(item:, view_mode:, position:, index: nil)`. `index` is the item's zero-based place on the rendered page; `nil` means unknown and degrades to lazy cover loading.

- [ ] **Step 1: Write the failing tests**

**No books fixture has an attached cover**, so `Books::CardComponent` renders its 📖 placeholder and emits no `<img>` at all. That is why the test being replaced here only ever made *negative* assertions — they pass whether or not the loading strategy is right. Attach a cover so the assertions mean something, using the pattern already established in `test/controllers/books/lists_controller_test.rb:166-170`.

In `test/components/user_lists/show/item_component_test.rb`, **replace** the test named `"grid_view passes the item's position through as a cover-loading index"` — it asserts the exact coupling this task removes — with:

```ruby
  # No books fixture ships an attached cover, and without one the card renders a
  # placeholder with no <img> to assert against.
  def attach_cover(book)
    image = Image.new(parent: book, primary: true)
    image.file.attach(io: StringIO.new("fake image data"), filename: "cover.jpg", content_type: "image/jpeg")
    image.save!
    book.reload
  end

  test "grid_view eager-loads covers by page index, not by list position" do
    item = user_list_items(:regular_user_books_item_1)
    attach_cover(item.listable)

    # A ranking-sorted page can put list position 40 first. The cover must still
    # load eagerly, because what matters is where the card sits on the page.
    render_inline(Component.new(item: item, view_mode: "grid_view", position: 40, index: 0))
    assert_selector "img[loading='eager']"

    render_inline(Component.new(item: item, view_mode: "grid_view", position: 1, index: 40))
    assert_selector "img[loading='lazy']"
  end

  test "grid_view falls back to lazy covers when no index is given" do
    item = user_list_items(:regular_user_books_item_1)
    attach_cover(item.listable)

    render_inline(Component.new(item: item, view_mode: "grid_view", position: 1))

    assert_selector "img[loading='lazy']"
  end

  test "a book grid card carries the item's list position as its rank badge" do
    item = user_list_items(:regular_user_books_item_1)
    render_inline(Component.new(item: item, view_mode: "grid_view", position: 12, index: 11))

    assert_selector "div.card .badge", text: "#12"
  end
```

The badge test needs no cover. `Books::CardComponent` renders the badge as `<div class="badge badge-primary font-bold"><span class="sr-only">Rank </span>#12</div>`; `render_inline` applies no CSS, so the node's text is `"Rank #12"` and Capybara's default substring match on `"#12"` matches it.

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/components/user_lists/show/item_component_test.rb
```

Expected: FAIL — `ArgumentError: unknown keyword: :index` on the tests that pass it, and a missing-badge failure on the third.

- [ ] **Step 3: Add the `index:` kwarg**

`app/components/user_lists/show/item_component.rb` — the initializer becomes:

```ruby
  def initialize(item:, view_mode:, position:, index: nil)
    @item = item
    @view_mode = view_mode.to_s
    @position = position
    @index = index
  end
```

and `index` joins the reader:

```ruby
  attr_reader :item, :view_mode, :position, :index
```

The default is `nil`, never `0`: `Books::CardComponent#above_fold?` is `index.present? && index < EAGER_IMAGE_COUNT`, so `nil` degrades to lazy/auto. A `0` default would mark every unknown position as above the fold — the exact failure that method's comment warns about.

- [ ] **Step 4: Pass rank and the real index to the books card**

In the same file, the `Books::Book` branch of `listable_card` becomes:

```ruby
    when Books::Book then Books::CardComponent.new(book: listable, rank: position, index: index)
```

Music and games are unchanged — neither card takes `rank:` or `index:`.

- [ ] **Step 5: Pass the index from the view**

`app/views/my_lists/show.html.erb` — the `<tbody>` loop (lines 99–101) becomes:

```erb
              <% @items.each_with_index do |item, index| %>
                <%= render UserLists::Show::ItemComponent.new(item: item, view_mode: @view_mode, position: item.position, index: index) %>
              <% end %>
```

and the card-container loop (lines 108–110) becomes:

```erb
          <% @items.each_with_index do |item, index| %>
            <%= render UserLists::Show::ItemComponent.new(item: item, view_mode: @view_mode, position: item.position, index: index) %>
          <% end %>
```

The index is page-local, which is what `EAGER_IMAGE_COUNT` wants — page 2 starts at 0 again and eager-loads its own top row.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bin/rails test test/components/user_lists/show/item_component_test.rb
```

Expected: PASS.

- [ ] **Step 7: Run the full suite and lint**

```bash
bin/rails test
bundle exec standardrb
```

Expected: PASS, 0 failures, no offenses.

- [ ] **Step 8: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/user-lists-grid-default
git add web-app/app/components/user_lists/show/item_component.rb web-app/app/views/my_lists/show.html.erb web-app/test/components/user_lists/show/item_component_test.rb
git commit -m "Badge My Lists grid cards and fix their eager-load window

Books grid cards now carry the item's list position, matching /lists/:id
and the numbering the list view already prints. index is passed from the
page loop instead of derived from position, which was wrong under
?sort=ranking: it eager-loaded six arbitrary covers.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: End-to-end verification

Nothing to implement. This is the gate before the branch is offered for review.

**Files:** none modified unless a check fails.

- [ ] **Step 1: Full suite**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/user-lists-grid-default/web-app
bin/rails db:test:prepare && bin/rails test
```

Expected: 0 failures, 0 errors, and a run count of **5392** — baseline 5386 plus six net new tests: Task 2 adds two, Task 5 adds two, Task 6 replaces one test with three.

- [ ] **Step 2: Eager-loading check, the way CI runs it**

```bash
CI=true bin/rails test test/components/user_lists test/models/user_list_test.rb
```

Expected: PASS. CI eager-loads, so a constant referenced across component namespaces fails here before it fails in CI.

- [ ] **Step 3: Lint**

```bash
bundle exec standardrb
```

Expected: no offenses.

- [ ] **Step 4: Playwright**

Needs a local dev server (`bin/dev`) and `e2e/.env`.

The signed-in specs live in the `books-account` project and the anonymous ones in `books` (see `e2e/playwright.config.ts:48,66`), so both are needed:

```bash
yarn test:e2e --project=books --project=books-account
```

Expected: PASS, including `books/account/my-lists.spec.ts`, `books/account/add-to-list.spec.ts` and `books/public-list.spec.ts`. The add-to-list specs are the only guard that the new `#N` badge did not disturb the widget sitting above `Books::CardComponent`'s stretched-link overlay.

If the admin/account specs all time out on the public homepage, the e2e user lost its role in a dev-DB reseed — run `bin/rails e2e:admin` and retry rather than debugging the specs.

- [ ] **Step 5: Look at the actual pages**

With `bin/dev` running, open on the books host:

- `/my/lists` → open **My Favorite Books**. It must land on grid, two covers across at phone width and six at desktop, each with a `#N` badge, identical in density to `/`.
- Click **List**, confirm descriptions come back and the URL reads `view_mode=list_view`; click **Table**; confirm the switcher order reads **Grid · List · Table**.
- `/` and any `/author/:slug` → unchanged from before this branch.

- [ ] **Step 6: Confirm the diff contains nothing unintended**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/user-lists-grid-default
git diff main --stat
grep -rn "default_view" web-app/app web-app/test web-app/e2e
```

Expected: the second command prints nothing. `docs/old_site/` and `docs/specs/completed/` must not appear in the diff.

---

## Deployment note

Merging to `main` auto-builds and SSH-deploys to production, so the migration runs there on deploy. In production it touches roughly 440 rows (music, games, movies) — the books lists are not there yet. The Task 3 change is what protects them when they eventually are.
