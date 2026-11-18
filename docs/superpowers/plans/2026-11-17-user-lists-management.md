# User Lists Management (web Phase B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Members can create, edit, reorder and delete their lists on the web, and the list pages
lose the List view and the "Edit completion date for …" clutter.

**Architecture:**
- Create, rename and delete move from the API controller into shared services, which both the API
  and the web call.
- The web gets a new Edit list page. Every move, remove, undo and date change on it is a Turbo
  form or fetch that answers with a Turbo Stream. The stream **morphs** the rows in place and
  appends a server-rendered toast, so there is no navigation, frame reload or scroll jump.
- SortableJS provides drag inside our own Stimulus controller. The ⋯ menu's actions are plain
  `button_to` forms and need no JavaScript.

**Tech Stack:** Rails 8, Turbo 8 (turbo-rails 2.0.23, morph), Stimulus, ViewComponent 4.23,
daisyUI 5 / Tailwind 4, SortableJS 1.15.7, Minitest + Mocha, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-17-user-lists-management-design.md`. Read it first. The
plan argues from it.

**Two PRs.** Tasks 1–6 are **PR 1** (dashboard and list page). Tasks 7–11 are **PR 2** (Edit list
page). Finish PR 1 (suite green, E2E green, pushed only when Shane asks) before starting Task 7 on
the same branch or a branch cut from it.

## Global Constraints

- Run Rails/yarn commands from `web-app/`; docs live in the repo-root `docs/`.
- Generators for new controllers, components and migrations:
  - Controllers: `bin/rails generate controller … --skip-routes --no-helper`.
  - Components: `bin/rails generate view_component:component …`.
  - Migrations: `bin/rails generate migration …`.
  - Each generator creates the matching test file.
- Services go in `app/lib/services/user_lists/`, use `Services::UserLists::MutationResult` (it is
  the Result struct these services already share), and run writes under
  `Services::UserLists::OwnerMutation`.
- **No flash.** No public layout renders flash, so every confirmation or error is a toast.
  A Turbo Stream appends `Toast::MessageComponent` (Task 5) to `#toast-region`.
- **Every non-2xx answer to a Turbo request is a Turbo Stream**, never `head` or an HTML error page.
  Copy `ReviewsController`'s `rescue_from` set for `Pundit::NotAuthorizedError`,
  `ActiveRecord::RecordNotFound` and `ActionController::InvalidAuthenticityToken`. Those
  controllers also need a signed-out answer of `render turbo_stream: [toast], status: :unauthorized`
  instead of `require_signed_in!`'s redirect to `/`.
- **No scroll jump.** A write on the list page or the Edit page never navigates, never reloads a
  frame, and never changes `window.scrollY`.
- `prevent_caching` on every action. Load lists through `current_user.user_lists` so a non-owner
  gets a 404.
- These pages serve books, music and games. Every new view must render for `Books::Book`,
  `Music::Album`, `Music::Song` (always tabular) and `Games::Game` listables. Movies is out of
  scope; don't break it, but don't add tests for it.
- Run annotaterb on every migration (`bin/rails db:migrate` does it). Never set
  `ANNOTATERB_SKIP_ON_DB_TASKS`.
- Before claiming done: `bin/rails test`, `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`,
  and the Playwright specs named in each PR's last task (check port 3000 belongs to this worktree
  first, per AGENTS.md).
- Exact copy (copy it verbatim):
  - Favorites note: `Your Favorites count toward the site rankings. Put them in order and the
    %{noun} near the top count for more.`
  - Dashboard Favorites card line: `Counts toward the site rankings`
  - Locked-name hint: `Built-in lists keep their names.`
  - Sort labels: `Your order`, `Recently added`, `Ranking`
  - Table placeholder: `Add date`
  - Completion labels: read → `Finished`, listened → `Listened`, played → `Played`,
    beaten → `Beaten`, watched → `Watched`

## Review Focus

1. **Stale item id.** Someone moves or removes an item that another tab already removed. Expect a
   404 Turbo Stream with an error toast and the rows morphed back to the truth. The page must never
   be replaced by `public/404.html`. Covered in Task 9.
2. **Session expired on a Turbo write.** Expect a 401 stream with a "Sign in again" toast, not a
   redirect that Turbo follows to the homepage. Covered in Task 9 and Task 4.
3. **Bad position.** "Move to position" with 0, more than the item count, or `abc`. Expect a 422
   stream with a toast, and nothing moves. Covered in Task 9.
4. **Undo that can no longer apply.** The list was deleted, or the book is already back on the
   list. Expect a toast, no 500, and no duplicate row. Covered in Tasks 8 and 9.
5. **Invalid CSRF token** on any Turbo write. Expect a 422 empty stream, not `public/422.html`.
   Covered in Task 9 and Task 4, with `allow_forgery_protection` flipped on for one request, as in
   `reviews_controller_test.rb`.

---

# PR 1 — Dashboard and list page

### Task 1: Shared list services; the API and the modal use them

**Files:**
- Create: `app/lib/services/user_lists/create_list.rb`, `update_list.rb`, `delete_list.rb`
- Test: `test/lib/services/user_lists/{create_list,update_list,delete_list}_test.rb`
- Modify: `app/controllers/api/v1/books/my/lists_controller.rb` (`update`, `destroy`,
  `create_list`, `name!`, `description!`)
- Modify: `app/controllers/user_lists_controller.rb#create` (modal JSON create)
- Modify: `app/policies/user_list_policy.rb#destroy?`, `test/policies/user_list_policy_test.rb`

**Interfaces:**
- Produces:
  - `Services::UserLists::CreateList.call(user:, klass:, name:, description: nil, public: false) -> MutationResult`
    - `data: {list:}`
    - `errors` uses exactly the strings the API returns today
  - `Services::UserLists::UpdateList.call(list:, attrs:) -> MutationResult`
    - `attrs` holds any of `:name, :description, :public`
    - refuses `:name` on `list.default?` with `"A default list cannot be renamed"`
  - `Services::UserLists::DeleteList.call(list:) -> MutationResult`
    - refuses a default list with `"A default list cannot be deleted"`
    - otherwise runs `OwnerMutation`, then `UserListItem.where(user_list_id:).delete_all`, then
      `list.destroy!`, then `list.user.touch`. The touch is there because `delete_all` skips the
      item callbacks that normally touch the user and refresh the widget state.
  - `Services::UserLists::ListRules::NAME_MAX = 100`, `DESCRIPTION_MAX = 1_000`
    - `ListRules.normalize_name(raw) -> String | nil` strips; returns nil when blank, too long or
      containing NUL
    - `ListRules.normalize_description(raw) -> String | nil | :invalid` strips; blank → nil
  - `UserListPolicy#destroy?` = `(owner? || global_admin?) && !record.default?`

- [ ] **Step 1: Write failing service tests**
  - `create_list_test.rb`
    - "creates a custom list of the given class": `list.list_type == "custom"` and `list.public == false`.
    - "strips the name and stores a blank description as nil".
    - "fails on a blank, 101-character or NUL name": `result.success?` false, nothing created.
  - `update_list_test.rb`
    - "renames a custom list".
    - "refuses to rename a default list but saves its description and public": with
      `user_lists(:regular_user_books_read)`, calling with `attrs: {name: "X"}` fails, while
      `{description: "d", public: true}` succeeds.
  - `delete_list_test.rb`
    - "deletes a custom list and its items" (`regular_user_custom_albums`, with
      `assert_difference "UserListItem.count", -1`).
    - "refuses a default list".
    - "touches the owner".

- [ ] **Step 2: Run them, expect FAIL** — `bin/rails test test/lib/services/user_lists/create_list_test.rb test/lib/services/user_lists/update_list_test.rb test/lib/services/user_lists/delete_list_test.rb` → uninitialized constant.

- [ ] **Step 3: Implement the three services and `ListRules`.** Lift the rules out of the API
  controller as they are; don't invent new ones. `CreateList` does not take the owner lock; callers
  that add books hold it, as `create_list` does today.

- [ ] **Step 4: Point the callers at the services.**
  - API `update` and `destroy` call `UpdateList` and `DeleteList`, mapping a failure to
    `refuse(result.errors.first)`.
  - API `name!` and `description!` use `ListRules`, keeping their 400 messages.
  - API `create_list` calls `CreateList` inside its existing `OwnerMutation`.
  - `UserListsController#create` uses `CreateList` and keeps its JSON shape.
  - Change `UserListPolicy#destroy?`, and add the policy test "destroy? refuses a default list, even
    for a global admin".

- [ ] **Step 5: Run the touched suites, expect PASS unchanged:** `bin/rails test test/lib/services/user_lists test/controllers/api/v1/books/my test/controllers/user_lists_controller_test.rb test/policies/user_list_policy_test.rb`. The API tests are the regression check, so don't edit them.

- [ ] **Step 6: Commit** — `git commit -m "Extract shared create/update/delete list services"`

### Task 2: Remove the List view mode

**Files:**
- Create: migration `MoveListViewUserListsToGridView`
- Modify: `app/models/user_list.rb` (enum, `VIEW_MODE_LABELS`)
- Modify: `app/components/user_lists/show/item_component.rb` + `.html.erb` (delete the list-view
  branch, `title_link`, `description`, `cover_image`, `cover_aspect_class` if unused)
- Modify: `app/controllers/my_lists_controller.rb#persist_view_mode` / `show`
- Tests: `test/models/user_list_test.rb`, `test/components/user_lists/show/item_component_test.rb`,
  `test/controllers/my_lists_controller_test.rb`

**Interfaces:**
- Produces:
  - `enum :view_mode, {table_view: 1, grid_view: 2}, default: :grid_view`
    - Integer 0 is retired, and the existing numbers must not change.
  - `VIEW_MODE_LABELS = {"grid_view" => "Grid", "table_view" => "Table"}`

- [ ] **Step 1: Failing tests**
  - Model: "view_mode offers only grid_view and table_view" (`assert_equal %w[table_view grid_view], UserList.view_modes.keys`).
  - Controller: "a list_view param falls back to the stored view mode and is not persisted".
    The owner GETs `?view_mode=list_view`, gets a 200, and `@list.reload.view_mode` is unchanged.
  - Delete the existing list-view tests rather than adapting them.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Migration**
  - The body is `execute "UPDATE user_lists SET view_mode = 2 WHERE view_mode = 0"`.
  - `down` is a no-op.
  - Run `bin/rails db:migrate`, which runs annotaterb.
  - Check the annotation diff. The column default is unchanged, so expect no column changes. Drop
    any lines for columns that belong to another branch.
  - Then update the enum, the labels and the component. The controller already ignores
    unknown modes, because it checks `UserList.view_modes.key?`. Verify that the test passes and
    don't add code for it.

- [ ] **Step 4: Run** `bin/rails test test/models/user_list_test.rb test/components/user_lists test/controllers/my_lists_controller_test.rb` → PASS.

- [ ] **Step 5: Commit** — `git commit -m "Remove the List view mode from user lists"`

### Task 3: Display strings on the models

**Files:**
- Modify: `app/models/user_list.rb`, `app/models/{books,games,movies}/user_list.rb`,
  `app/models/music/albums/user_list.rb`
- Test: `test/models/user_list_test.rb` plus each subclass's model test

**Interfaces:**
- Produces:
  - `UserList.completion_labels -> Hash{Symbol => String}`
    - Base `{}`; Books `{read: "Finished"}`; Music::Albums `{listened: "Listened"}`; Games
      `{played: "Played", beaten: "Beaten"}`; Movies `{watched: "Watched"}`.
  - `UserList#completion_label -> String`
    - `self.class.completion_labels.fetch(list_type.to_sym, "Completed")`
  - `UserList#counts_toward_rankings? -> Boolean`
    - `favorites? && self.class.in?(UserList.generating_subclasses)`
    - Every subclass's enum defines `favorites`.
  - `UserList#listable_noun -> String`
    - `self.class.listable_class.model_name.human(count: 2).downcase`, giving "books", "albums",
      "songs" or "games".

- [ ] **Step 1: Failing tests**
  - `regular_user_books_read.completion_label == "Finished"`
  - `regular_user_music_albums_listened.completion_label == "Listened"`
  - `regular_user_books_favorites.counts_toward_rankings?` is true
  - `regular_user_movies_favorites.counts_toward_rankings?` is false
  - `regular_user_custom_albums.counts_toward_rankings?` is false
  - `regular_user_music_songs_favorites.listable_noun == "songs"`

- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** **Step 4: Run, expect PASS.**

- [ ] **Step 5: Commit** — `git commit -m "Add completion labels and rankings flag to user lists"`

### Task 4: Dashboard — New list dialog, create action, Favorites card line

**Files:**
- Modify: `config/routes.rb`
  - Add `post "my/lists", to: "my_lists#create"` beside the other `my/lists` routes.
- Modify: `app/controllers/my_lists_controller.rb` (add `create`, add `:create` to
  `require_signed_in!`, plus a stream-aware signed-out handler for `create`)
- Create component: `UserLists::Dashboard::NewListDialogComponent` (`types:` Array<Class>)
- Modify: `app/views/my_lists/index.html.erb`, `UserLists::Dashboard::ListCardComponent`
- Tests: `test/controllers/my_lists_controller_test.rb`, component tests

**Interfaces:**
- Consumes: `CreateList` (Task 1), `counts_toward_rankings?` (Task 3).
- Produces:
  - `POST /my/lists` with params `user_list[name, description, public, type]`.
    - `type` must be one of `UserList.subclasses_for(Current.domain).map(&:name)`. When the domain
      has one subclass, the field is hidden and pre-filled.
    - **Success:** `redirect_to my_list_path(list), status: :see_other`. The form is a normal Turbo
      form and the redirect navigates.
    - **Failure:** `render turbo_stream: turbo_stream.update("new-list-errors", <errors>)` with
      status 422.
  - The dialog is `<dialog id="new-list-dialog">`. "+ New list" opens it with daisyUI
    `modal`/`showModal()` through a tiny inline `onclick`. Plain `<dialog>` markup is fine; this
    needs no Stimulus.

- [ ] **Step 1: Failing controller tests (music host, as the file does today)**
  - "create makes a custom album list and redirects to it".
  - "create on music requires a valid type": `Games::UserList` → 422, and the response
    `media_type == "text/vnd.turbo-stream.html"`.
  - "create with a blank name answers 422 as a turbo stream and creates nothing".
  - "create signed out answers 401 as a turbo stream": `post my_lists_path, as: :turbo_stream`.
  - "create with an invalid CSRF token answers 422 as a turbo stream". Flip
    `ActionController::Base.allow_forgery_protection` for the request, as
    `reviews_controller_test.rb` does.
  - Books host: "dashboard shows the rankings line on the favorites card only".

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement.**
  - The dialog fields are name (required, maxlength 100), description (maxlength 1000), the
    "Make this list public" checkbox, and a type `<select>` only when `types.size > 1`, labelled
    with `klass.listable_class.model_name.human(count: 2)`.
  - Use daisyUI 5 `fieldset`/`fieldset-legend`/`label`/bare `input`, none of the v4 classes.
  - The rankings card line renders only when `user_list.counts_toward_rankings?`.

- [ ] **Step 4: Run, expect PASS.** **Step 5: Commit** — `git commit -m "Create lists from the My Lists dashboard"`

### Task 5: Toast messages from the server, and finish dates without the clutter

**Files:**
- Create component: `Toast::MessageComponent` (`message:`, `type: :success`, `action: nil`, `ttl: 4000`)
- Create Stimulus: `app/javascript/controllers/toast_item_controller.js` (register with `bin/rails stimulus:manifest:update`)
- Create component: `UserLists::CompletionDateComponent` (`item:`, `variant:` `:text` | `:table`, `editable:`)
- Modify: `UserLists::Show::ItemComponent` (+ erb): grid shows `variant: :text` under the card; the
  table cell renders `variant: :table`. Delete every "Edit completion date for" button.
- Modify: `UserListItemsController#update_completion`: answer Turbo Stream instead of redirect
- Modify: `user_list_completion_controller.js` (close on `turbo:submit-end` success; send `variant`)
- Modify: `UserLists::Show::CompletionDialogComponent` (hidden `variant` field)
- Tests: component tests, `test/controllers/user_list_items_controller_test.rb`

**Interfaces:**
- Produces:
  - `Toast::MessageComponent`
    - Renders `<div class="alert alert-#{type} shadow-lg" role="status" data-controller="toast-item" data-toast-item-ttl-value="#{ttl}">`.
    - Inside: the message, plus `button_to action[:label], action[:url], method: action[:method], params: action[:params], class: "btn btn-sm"` when an action is given.
    - Task 9's Undo uses `action`.
  - `toast_item_controller.js` removes its element after `ttl` with the same fade the existing
    `toast_controller.js` uses.
  - `UserLists::CompletionDateComponent`
    - The root element's id is `dom_id(item, :completion)`. Callers replace the element by this id.
    - `:text` renders `"#{label} #{date.to_fs(:long)}"` (e.g. "Finished March 3, 2026") as muted
      small text, or nothing when the item has no date.
    - `:table` with `editable` renders a `button.link` showing the date, or `Add date` in muted
      style, with `aria-label="Edit #{label.downcase} date for #{title}"`. It carries the existing
      `data-action="user-list-completion#open"` attributes plus `data-variant="table"`.
    - `:table` without `editable` renders plain text.
  - `PATCH /user_list_items/:id/completion`, Turbo Stream responses:
    - **Success:** `turbo_stream.replace(dom_id(item, :completion), CompletionDateComponent.new(item:, variant: params[:variant] || "table", editable: true))`
      plus `turbo_stream.append("toast-region", Toast::MessageComponent.new(message: completion_message(result)))`.
    - **Failure:** an error toast only, status 422.
    - The JSON path is unchanged.
  - The table header cell becomes `@list.completion_label` (e.g. "Finished") instead of "Completed".

- [ ] **Step 1: Failing tests**
  - Component, `:table`, owner, no date: renders "Add date" with aria-label "Edit finished date for <title>".
  - Component, `:text`, with a date: renders "Finished".
  - ItemComponent: "grid view renders no completion buttons": `assert_no_selector "button", text: /completion date/i`.
  - Controller: "update_completion as turbo stream replaces the date and appends a toast".
    `patch user_list_item_completion_path(item), params: {user_list_item: {completed_on: "2026-03-03"}, variant: "table"}, as: :turbo_stream`.
    Expect a 200 and a body that includes `turbo-stream action="replace" target="#{dom_id(item, :completion)}"`
    and `target="toast-region"`.
  - Controller: "an invalid date answers 422 with an error toast and keeps the old date".

- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** In JS, `open()` copies `opener.dataset.variant` into the form's hidden `variant` field. A `turbo:submit-end` listener on the form closes the dialog when `event.detail.success` is true.

- [ ] **Step 4: Run, expect PASS.** **Step 5: Commit** — `git commit -m "Quiet finish dates and stream completion edits in place"`

### Task 6: List page sort, Favorites note, E2E and docs (closes PR 1)

**Files:**
- Modify: `app/controllers/my_lists_controller.rb#show`: `@sort` accepts `"position" | "added" | "ranking"`
- Modify: `app/views/my_lists/show.html.erb`: sort labels, the Favorites note
- Create component: `UserLists::FavoritesNoteComponent` (`user_list:`); `render?` is `user_list.counts_toward_rankings?`
- Tests: controller and component tests
- E2E: `e2e/tests/books/account/my-lists.spec.ts`, `e2e/tests/books/account/reading-goals.spec.ts`
- Docs: `docs/features/user-lists.md`

**Interfaces:**
- Produces: `FavoritesNoteComponent`, renders the Global Constraints copy with
  `noun: user_list.listable_noun`. Task 7 reuses it on the Edit page.
- `sort=added` orders by `user_list_items.created_at DESC, user_list_items.id DESC`. CSV follows it,
  as it follows the other sorts.

- [ ] **Step 1: Failing tests**
  - Controller: "sort=added lists the newest item first". Make the newest fixture item's
    `created_at` later with `update_column` in the test; don't rely on fixture order.
  - Controller: "an unknown sort falls back to position".
  - Component: renders the "books near the top" copy for `regular_user_books_favorites`, and
    nothing for `regular_user_books_read`.

- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** **Step 4: Run, expect PASS.**

- [ ] **Step 5: E2E.**
  - In `my-lists.spec.ts`:
    - Replace the List view test with "a list page offers Grid and Table only".
    - Add "creating a list from the dashboard lands on the new list". Use a unique name with a
      timestamp, then delete the list through the API in `afterEach`, or rely on
      `e2e:prepare`'s reset. Read `docs/features/e2e-testing.md` to choose.
    - Add "the favorites list explains that it counts toward the rankings".
    - Add "Recently added puts the newest book first".
  - In `reading-goals.spec.ts`:
    - Before opening the date dialog, switch the Read list to **Table** (grid has no control).
    - Target the trigger by its new accessible name, `Edit finished date for ${title}`.
    - Assert that the page did not navigate (the URL is unchanged) and that the row shows the new
      date without a reload.

- [ ] **Step 6: Verify.** Run `bin/rails test`, `bundle exec standardrb` and `CI=1 bin/rails zeitwerk:check`. Then check the port-3000 owner and run `yarn build:all && yarn test:e2e e2e/tests/books/account/my-lists.spec.ts e2e/tests/books/account/reading-goals.spec.ts e2e/tests/books/account/add-to-list.spec.ts`. Expect everything green.

- [ ] **Step 7: Update `docs/features/user-lists.md`.**
  - View modes are Grid and Table.
  - The dashboard can create lists.
  - The Recently added sort.
  - Finish-date display.
  - Shared list services.

- [ ] **Step 8: Commit** — `git commit -m "Recently added sort, Favorites rankings note, PR 1 E2E and docs"`. Stop here. PR 1 is complete.

---

# PR 2 — Edit list page

### Task 7: Edit page shell — details form, delete, Edit button

**Files:**
- Modify: `config/routes.rb`, beside the `my/lists` routes:
  - `get "my/lists/:id/edit", to: "my_lists#edit", as: :edit_my_list`
  - `get "my/lists/:id/edit/page/:page", to: "my_lists#edit", as: :edit_my_list_page, constraints: {page: /\d+/}`
  - `patch "my/lists/:id", to: "my_lists#update"`
  - `delete "my/lists/:id", to: "my_lists#destroy"`
  - change the legacy `user_lists/:id/edit` redirect target to `/my/lists/%{id}/edit`
- Modify: `app/controllers/my_lists_controller.rb` (`edit`, `update`, `destroy`)
- Create: `app/views/my_lists/edit.html.erb`
- Create components: `UserLists::Edit::DetailsFormComponent` (`user_list:`),
  `UserLists::Edit::RowComponent` (`item:`, `page:`), `UserLists::Edit::RowsComponent` (`user_list:`, `items:`, `pagy:`)
- Modify: `app/views/my_lists/show.html.erb` (owner-only "Edit list" link to `edit_my_list_path`)
- Tests: controller, component tests

**Interfaces:**
- Consumes: `UpdateList`, `DeleteList` (Task 1); `FavoritesNoteComponent` (Task 6); `CompletionDateComponent` `:text` (Task 5).
- Produces:
  - `edit` loads `current_user.user_lists.where(type: types).find(params[:id])`, scoped to
    `Current.domain` as `show` is.
    - `@items = list.user_list_items.ordered.includes(listable: list.class.listable_display_includes)`,
      paged by `pagy_path(…, limit: 100)`.
    - There is **no** `catalog_items` filter (the spec's "owner sees every item" decision).
  - `RowsComponent` renders `<div id="edit-list-rows" data-user-list-edit-target="rows">` holding
    the pager and the rows. It is the morph target for Task 9.
  - `RowComponent`:
    - The root is `<div id="<%= dom_id(item) %>" data-position="<%= item.position %>" data-item-id="<%= item.id %>">`.
    - It shows a position badge (`item.position`), a cover thumbnail where the listable has one,
      the title and by-line, and `CompletionDateComponent` `:text` when
      `list.completed_on_enabled?`. A list without a date shows the faint "No #{label.downcase} date".
    - Then come a daisyUI `dropdown` ⋯ menu (Task 9 fills its actions), a ✕ slot (Task 9), and a
      drag handle `<span data-sortable-handle aria-hidden="true">`.
    - Pull the by-line and title helpers out of `Show::ItemComponent` into a shared
      `UserLists::ListableDisplay` module rather than copying them.
  - `DetailsFormComponent`:
    - A `form_with model: user_list, url: my_list_path(user_list), method: :patch` form with name
      (read-only plus the locked hint when `default?`), description, public, and Save.
    - Failure: `turbo_stream.update("list-details-errors", …)` with status 422.
    - Success: `turbo_stream.replace("list-details", DetailsFormComponent…)` plus a "Saved" toast.
  - `destroy`:
    - `DeleteList`, then `redirect_to my_lists_path, status: :see_other`.
    - The button is `button_to … method: :delete, form: {data: {turbo_confirm: "Delete “#{name}”? This removes the list and its #{pluralize(count, 'item')}. It can't be undone."}}`.
    - It renders only when `!default?`.
    - A refused delete answers 422 with an error toast.

- [ ] **Step 1: Failing controller tests**
  - "edit renders for the owner".
  - "edit 404s for another user's list".
  - "edit shows provisional books to the owner". For a books list, give an item a listable outside
    `Books::Book.catalog` (check how existing tests build a provisional book; grep `provisional` in
    `test/`).
  - "edit renders a songs list" (`regular_user_music_songs_favorites`).
  - "update renames a custom list".
  - "update refuses to rename a default list, answers 422 as a turbo stream, name unchanged".
  - "update saves a default list's description".
  - "destroy deletes a custom list and redirects to the dashboard".
  - "destroy refuses a default list with 422 and keeps it".
  - "show renders the Edit list link for the owner only".

- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** **Step 4: Run, expect PASS.**

- [ ] **Step 5: Commit** — `git commit -m "Edit list page: details form, delete, rows"`

### Task 8: `RestoreItem` service (Undo)

**Files:**
- Create: `app/lib/services/user_lists/restore_item.rb`
- Test: `test/lib/services/user_lists/restore_item_test.rb`

**Interfaces:**
- Consumes: `AddItem`, `UpdateCompletion`, `MoveItem` (existing).
- Produces: `Services::UserLists::RestoreItem.call(user_list:, listable:, position:, completed_on:) -> MutationResult`
  - Runs in one `OwnerMutation`:
    1. If `listable` is already on `user_list`, fail with `"Already back on this list"`.
    2. `AddItem`.
    3. `UpdateCompletion` to `completed_on` when the list has completion dates. This tracks the
       goal change.
    4. `MoveItem` to `[position, count].min`.
  - `data: {item:}`.

- [ ] **Step 1: Failing tests**
  - "restores a removed book to its old position and date". Give the item at position 2 of
    `regular_user_books_read` a `completed_on` (add items in the test if the list has fewer than 3).
    Remove it with `RemoveItems`, restore it, and expect position 2 and the same `completed_on`.
  - "fails without a duplicate when the item is already on the list".
  - "clamps a position past the end".
  - "sets manually_ordered only if the move was real" (follows MoveItem).

- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** **Step 4: Run, expect PASS.** **Step 5: Commit** — `git commit -m "Add RestoreItem for undoing a removal"`

### Task 9: Move, remove and undo endpoints that morph in place

**Files:**
- Generate: `MyListItemsController` (`bin/rails generate controller my_list_items --skip-routes --no-helper`)
- Modify: `config/routes.rb`:
  - `patch "my/lists/:id/items/:item_id/position", to: "my_list_items#move", as: :move_my_list_item`
  - `delete "my/lists/:id/items/:item_id", to: "my_list_items#destroy", as: :my_list_item`
  - `post "my/lists/:id/items/restore", to: "my_list_items#restore", as: :restore_my_list_item`
- Modify: `UserLists::Edit::RowComponent` (⋯ menu forms, ✕ form)
- Test: `test/controllers/my_list_items_controller_test.rb`

**Interfaces:**
- Consumes: `UpdateItem(item:, position:)`, `RemoveItems(user_list:, listables:)` (existing),
  `RestoreItem` (Task 8), `RowsComponent` (Task 7), `Toast::MessageComponent` (Task 5).
- Produces, for every action:
  - Params: `page` (the Edit page currently shown, default 1); `move` also takes
    `user_list_item[position]` (an Integer).
  - Every response, success or failure, includes
    `turbo_stream.replace("edit-list-rows", method: :morph) { RowsComponent for page }`, so a
    failure also morphs the rows back to the truth. It also includes a toast. Statuses: 200, 404
    (stale item), 422 (bad position or refused restore), 401 (signed out).
  - Toast copy:
    - A move whose target is off the current page: `Moved to ##{position}`.
    - A move on the same page: no toast.
    - Remove: `Removed #{title}`, with action `{label: "Undo", url: restore_my_list_item_path(list), method: :post, params: {listable_id:, position:, completed_on:, page:}}` and `ttl: 8000`.
    - Restore: `Restored #{title}`.
  - The ⋯ menu items are `button_to` forms posting to these routes:
    - Move to top: position 1.
    - Move to bottom: position = item count.
    - Move to position…: a `<form>` with `input type=number min=1 max=count required` inside the
      dropdown.
    - Set #{label.downcase} date…: shown when `completed_on_enabled?`. It is a button carrying the
      `user-list-completion#open` data with `data-variant="text"`, and the page renders
      `CompletionDialogComponent`.
  - ✕ is a `button_to` with `aria-label="Remove #{title}"`.

- [ ] **Step 1: Failing controller tests (`as: :turbo_stream`)**
  - "move puts the item at the position, morphs the rows, and sets manually_ordered".
  - "move past the end answers 422 with a toast and changes nothing".
  - "move with a non-integer position answers 422".
  - "move of an item from another user's list 404s as a turbo stream".
  - "move of a removed item 404s as a turbo stream with the rows morphed".
  - "destroy removes the item and offers Undo carrying its position and date".
  - "restore puts it back".
  - "restore when already present answers 422 without a duplicate".
  - "signed-out move answers 401 as a turbo stream".
  - "an invalid CSRF token answers 422 as a turbo stream".
  - Each test asserts `response.media_type == "text/vnd.turbo-stream.html"`.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement.**
  - Copy `ReviewsController`'s three `rescue_from` blocks, but make each one render the error toast
    and the morph rather than an empty stream.
  - Use a `before_action` that answers a signed-out request with
    `render turbo_stream: toast("Sign in again to edit this list", :error), status: :unauthorized`.
  - Parse the position with `Integer(params…, exception: false)`.

- [ ] **Step 4: Run, expect PASS.** **Step 5: Commit** — `git commit -m "Move, remove and undo on the Edit list page"`

### Task 10: Drag to reorder (SortableJS)

**Files:**
- `yarn add sortablejs@1.15.7` (the lockfile changes; Rollup's node-resolve bundles it)
- Create: `app/javascript/controllers/user_list_edit_controller.js` (register with `bin/rails stimulus:manifest:update`)
- Modify: `app/views/my_lists/edit.html.erb` (`data-controller="user-list-edit"`, values for the move URL template and the page)

**Interfaces:**
- Consumes: the `move` endpoint (Task 9); `#edit-list-rows` with its `rows` target (Task 7).
- Produces: `user-list-edit` controller with `static targets = ["rows"]` and `static values = { moveUrl: String, page: Number }`.
  - `moveUrl` holds `__ID__` in place of the item id.
  - It re-creates Sortable after each morph (listen for `turbo:morph-element` on the rows target,
    or re-create in a `rowsTargetConnected` callback).

- [ ] **Step 1: Implement the drop handler.** This is the one algorithm the tests don't determine:

```javascript
// Sortable onEnd: the moved row takes the stored position of the neighbour it displaced.
onEnd({ item, oldIndex, newIndex }) {
  if (oldIndex === newIndex) return
  const neighbour = newIndex > oldIndex ? item.previousElementSibling : item.nextElementSibling
  const target = Number(neighbour.dataset.position)
  this.#submitMove(item.dataset.itemId, target)
}
```

  - `#submitMove` sends a `fetch` PATCH with a form-encoded body
    (`user_list_item[position]`, `page`) and these headers:
    - `Accept: text/vnd.turbo-stream.html`
    - `X-CSRF-Token` from the meta tag
  - It always passes the response text to `Turbo.renderStreamMessage`, whatever the status, because
    the server always morphs back to the truth.
  - On a network error it dispatches
    `toast:show {type: "error", message: "Couldn't save that move. Reload the page to see your list."}`.
  - Sortable options:
    - `handle: "[data-sortable-handle]"`, `animation: 150`, `ghostClass: "opacity-50"`
    - `draggable` set to the row selector, so the pager isn't draggable

- [ ] **Step 2: Build and check by hand in a browser.**
  - Run `yarn build:all`, then `bin/rails server` (port 3000 must be this worktree's).
  - Open a Favorites list with more than 10 items. Scroll down. Drag row 8 above row 3.
  - Confirm that the numbers renumber, the page doesn't jump (`window.scrollY` unchanged), and
    nothing flashes.
  - Reload the page; the order has persisted.
  - Then on a phone-width viewport, touch-drag by the handle; the page still scrolls when you touch
    outside it.

- [ ] **Step 3: Commit** — `git commit -m "Drag to reorder on the Edit list page"`

### Task 11: Edit page E2E and docs (closes PR 2)

**Files:**
- Create: `e2e/tests/books/account/edit-list.spec.ts`
- Docs: `docs/features/user-lists.md`, and the comment block at the top of `MyListsController`
  (it still says the write actions are "Phase B")

- [ ] **Step 1: Write the E2E spec.** Use a seeded custom books list with at least 5 items, and
  extend `lib/tasks/e2e.rake` if none exists.
  - "drag reorders and survives a reload".
  - "Move to position… moves a book, and the page does not scroll". Scroll to a row, record
    `window.scrollY`, act, and assert it is unchanged and the URL is unchanged.
  - "Remove then Undo restores the book to its place".
  - "Set finished date from the ⋯ menu on the Read list updates the row in place".
  - "renaming a custom list saves", and "a built-in list's name is not editable and has no Delete".
  - "deleting a custom list returns to the dashboard without it".

- [ ] **Step 2: Run** `bin/rails test`, `bundle exec standardrb` and `CI=1 bin/rails zeitwerk:check`. Then check port 3000 and run `yarn build:all && yarn test:e2e e2e/tests/books/account/`. Expect everything green.

- [ ] **Step 3: Update `docs/features/user-lists.md`.**
  - The Edit page.
  - Save-per-move with morph.
  - Undo.
  - Built-in list rules.
  - How a reorder flips `manually_ordered`, and how that feeds the Favorites ranking.

  Remove "Phase B" from the "What's Not Yet Implemented" section.

- [ ] **Step 4: Commit** — `git commit -m "Edit list E2E and docs"`. PR 2 is complete.
