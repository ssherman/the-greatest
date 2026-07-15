# List-Items Single Modal + Pagination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the admin list-items table from rendering one `<dialog>` per row and from loading every item unbounded. One modal per page, loaded on demand; items paginated.

**Architecture:** Both fixes already have complete, working precedents in this codebase — copy them rather than inventing. The wizard's `Admin::Music::Wizard::SharedModalComponent` is a single `<dialog>` wrapping a Turbo Frame whose content loads on demand (its own comment reads *"This replaces per-item modal rendering to improve performance with large lists"*). `Admin::RankedListsController#index` + `app/views/admin/ranked_lists/index.html.erb` is a paginated collection rendered inside a lazy Turbo Frame, with frame-targeted pagination links.

**Tech Stack:** Rails 8, Turbo Frames, Stimulus, ViewComponent, Pagy, DaisyUI 5, Minitest + fixtures + Mocha, Playwright.

This is **increment 2** of `docs/superpowers/specs/2026-07-13-books-admin-ui-design.md` (decision D12).

## Why this matters

`app/views/admin/list_items/index.html.erb:78-81`:

```erb
<%# Render edit modals for each list item %>
<% list_items.each do |list_item| %>
  <%= render Admin::EditListItemModalComponent.new(list_item: list_item) %>
<% end %>
```

One `<dialog>` per row, each containing a full form and an autocomplete. And `Admin::ListItemsController#index` loads **every** item with no pagination.

The books lists are already migrated. The largest — "Our Users' Honorable Mention Favorite Books of All Time" — has **6,933 items**. That page would emit 6,933 dialogs and 6,933 table rows: megabytes of HTML, and the autocomplete components alone would lock up the browser. Music and games only survive this because their lists are small.

**This is a deliberate behavior change to the music and games admin**, unlike increment 1. The visible difference: the edit form loads on demand when you click Edit, instead of being pre-rendered; and the items table paginates.

## Global Constraints

- **Working directory is `web-app/`.** Run every command from there. Docs live at the project root in `docs/`, not `web-app/docs/`.
- Lint with `bundle exec standardrb` (NOT `bin/rubocop` — omakase, conflicting style). `--fix` autocorrects.
- **No code comments** unless they state a constraint the code cannot express.
- **No books code.** Books has no admin yet; this touches only the shared list-items surface that music and games use today.
- Full suite: `bin/rails test` (4,565 tests, 0 failures at branch HEAD). Must stay green.
- **The e2e suite works now** — 156/156. Run it: `yarn test:e2e`. It needs the dev server up. If admin specs fail with click timeouts on the public homepage, run `bin/rails e2e:admin` (the e2e user loses its role on a dev-DB reseed) — that is an environment fix, not a code failure.
- Tests: Minitest + fixtures + Mocha. Fixture names are semantic — check them. Auth: `sign_in_as(@user, stub_auth: true)`.
- Controller tests assert **behavior** (status codes, params, no errors) — never HTML/CSS/copy.

## Current shape (verified 2026-07-13)

**How the table gets on screen.** `Admin::Lists::ShowComponent` (`app/components/admin/lists/show_component.html.erb:249-254`) renders a **lazy** frame:

```erb
<%= helpers.turbo_frame_tag "list_items_list", loading: :lazy,
    src: admin_list_list_items_path(list) do %>
  <div class="flex justify-center py-8"><span class="loading loading-spinner loading-lg"></span></div>
<% end %>
```

That hits `Admin::ListItemsController#index` (`render layout: false`), which renders `app/views/admin/list_items/index.html.erb` — itself wrapped in `turbo_frame_tag "list_items_list"`.

**How the modal opens today.** Each row's Edit button is a bare `onclick`:
```erb
<button ... onclick="edit_list_item_modal_dialog_<%= list_item.id %>.showModal()">
```
targeting the per-row dialog rendered by `Admin::EditListItemModalComponent`, whose template lives at `app/components/admin/edit_list_item_modal_component/edit_list_item_modal_component.html.erb` and wraps a `<dialog id="edit_list_item_modal_dialog_#{id}">`.

**Routes** (`config/routes.rb:403,412`, inside the global `namespace :admin`):
```ruby
scope "list/:list_id", as: "list" do
  resources :list_items, only: [:index, :create] do
    collection { delete :destroy_all; delete :clear_positions }
  end
end
resources :list_items, only: [:update, :destroy]
```

**The controller's turbo_stream responses** in `create`, `update`, and `destroy` each re-render the index template with explicit locals:
```ruby
turbo_stream.replace("list_items_list",
  template: "admin/list_items/index",
  locals: {list: @list, list_items: @list.list_items.includes(:listable).order(:position)})
```
All three pass an **unpaginated** relation. They must be updated too, or pagination silently reverts to "all items" the moment anyone adds, edits, or deletes an item.

## The two precedents to copy

**1. Single on-demand modal** — `app/components/admin/music/wizard/shared_modal_component.html.erb`:
```erb
<dialog id="<%= dialog_id %>" class="modal"
        data-controller="shared-modal"
        data-action="turbo:frame-load->shared-modal#open">
  <div class="modal-box max-w-2xl overflow-visible">
    <%= helpers.turbo_frame_tag frame_id do %>
      <div class="flex justify-center py-8"><span class="loading loading-spinner loading-lg"></span></div>
    <% end %>
  </div>
  <form method="dialog" class="modal-backdrop"><button>close</button></form>
</dialog>
```
`shared_modal_controller.js` opens the dialog on `turbo:frame-load` and resets the frame to the spinner on close. A row's action link carries `data: {turbo_frame: FRAME_ID}`; the server responds with the form wrapped in a matching `turbo_frame_tag`, Turbo swaps it in, the frame-load event fires, the dialog opens. **Read `app/controllers/concerns/list_items_actions.rb#modal` for how the wizard serves that content.**

**2. Paginated collection in a frame** — `app/views/admin/ranked_lists/index.html.erb:70-74`:
```erb
<% if @pagy && @pagy.pages > 1 %>
  <div class="flex justify-center py-4 border-t border-base-300">
    <%== @pagy.series_nav(anchor_string: 'data-turbo-frame="ranked_lists_list"') %>
  </div>
<% end %>
```
with `Admin::RankedListsController#index` doing `@pagy, @ranked_lists = pagy(scope, limit: 25)` then `render layout: false`. The `anchor_string` is what keeps pagination links inside the frame instead of navigating the whole page. Note `<%==` (raw output) — `series_nav` returns HTML.

## File Structure

**Create:**
- `app/components/admin/edit_list_item_modal_component/` → keep the directory, but the component becomes the **shell** (see Task 1)
- `app/components/admin/edit_list_item_form_component.rb` + `app/components/admin/edit_list_item_form_component/edit_list_item_form_component.html.erb` — the form that loads into the frame
- `test/components/admin/edit_list_item_form_component_test.rb`

**Modify:**
- `app/components/admin/edit_list_item_modal_component.rb` + its template — becomes the single dialog shell
- `app/components/admin/lists/show_component.html.erb` — render the modal shell once
- `app/views/admin/list_items/index.html.erb` — Edit button becomes a frame-targeting link; delete the per-row modal loop; add pagination nav
- `app/controllers/admin/list_items_controller.rb` — add `edit`; paginate `index`; paginate the three turbo_stream re-renders
- `config/routes.rb` — add `:edit` to the shallow `resources :list_items`
- `test/controllers/admin/list_items_controller_test.rb`
- `test/components/admin/edit_list_item_modal_component_test.rb`

---

### Task 1: Split the modal into a shell + a form

The component currently takes a `list_item:` and renders a whole `<dialog>`. Split it: the **shell** renders one empty dialog per page; the **form** is what gets loaded into it on demand.

**Files:**
- Modify: `app/components/admin/edit_list_item_modal_component.rb` and `app/components/admin/edit_list_item_modal_component/edit_list_item_modal_component.html.erb`
- Create: `app/components/admin/edit_list_item_form_component.rb` and `app/components/admin/edit_list_item_form_component/edit_list_item_form_component.html.erb`
- Test: `test/components/admin/edit_list_item_modal_component_test.rb` (rewrite), `test/components/admin/edit_list_item_form_component_test.rb` (new)

**Interfaces:**
- Produces:
  - `Admin::EditListItemModalComponent.new` — **no arguments**. Renders one `<dialog id="edit_list_item_modal_dialog">` containing `turbo_frame_tag "edit_list_item_modal_content"`. Exposes `DIALOG_ID = "edit_list_item_modal_dialog"` and `FRAME_ID = "edit_list_item_modal_content"`.
  - `Admin::EditListItemFormComponent.new(list_item:)` — renders the form, wrapped in `turbo_frame_tag Admin::EditListItemModalComponent::FRAME_ID`. Keeps the existing `autocomplete_url`, `item_label`, `item_display_name`, `unverified_item_display_name`, and `metadata_json` methods, which move over from the old component **unchanged** (they already read from `Admin::DomainRouting`).

- [ ] **Step 1: Read the existing component and its test**

Read `app/components/admin/edit_list_item_modal_component.rb`, its template, and `test/components/admin/edit_list_item_modal_component_test.rb`. The five helper methods listed above move to the form component verbatim — do not rewrite them.

- [ ] **Step 2: Write the failing tests**

Rewrite `test/components/admin/edit_list_item_modal_component_test.rb` so it renders the shell with **no arguments** and asserts there is exactly one dialog with the constant id, containing the frame, and **no** form:

```ruby
require "test_helper"

class Admin::EditListItemModalComponentTest < ViewComponent::TestCase
  test "renders a single empty dialog with a turbo frame" do
    render_inline(Admin::EditListItemModalComponent.new)

    assert_selector "dialog##{Admin::EditListItemModalComponent::DIALOG_ID}", count: 1
    assert_selector "turbo-frame##{Admin::EditListItemModalComponent::FRAME_ID}", count: 1
    assert_no_selector "form[action]"
  end
end
```

Create `test/components/admin/edit_list_item_form_component_test.rb`. The fixture is **verified**: `list_items(:music_albums_item)` belongs to `lists(:music_albums_list)` with a `Music::Album` listable, so `Admin::DomainRouting.list_config` resolves and the autocomplete branch renders.

```ruby
require "test_helper"

class Admin::EditListItemFormComponentTest < ViewComponent::TestCase
  test "renders the edit form inside the shared modal frame" do
    list_item = list_items(:music_albums_item)

    render_inline(Admin::EditListItemFormComponent.new(list_item: list_item))

    assert_selector "turbo-frame##{Admin::EditListItemModalComponent::FRAME_ID}"
    assert_selector "input[name='list_item[position]']"
    assert_no_selector "dialog"
  end
end
```

`assert_no_selector "dialog"` is the load-bearing assertion — the form must NOT carry its own dialog any more; the shell owns the only one.

- [ ] **Step 3: Run them and see them fail**

Run: `bin/rails test test/components/admin/edit_list_item_modal_component_test.rb test/components/admin/edit_list_item_form_component_test.rb`
Expected: FAIL — `ArgumentError: missing keyword: :list_item` on the shell, `NameError: uninitialized constant Admin::EditListItemFormComponent` on the form.

- [ ] **Step 4: Write the shell**

`app/components/admin/edit_list_item_modal_component.rb`:

```ruby
# frozen_string_literal: true

class Admin::EditListItemModalComponent < ViewComponent::Base
  DIALOG_ID = "edit_list_item_modal_dialog"
  FRAME_ID = "edit_list_item_modal_content"

  def dialog_id
    DIALOG_ID
  end

  def frame_id
    FRAME_ID
  end
end
```

Its template, mirroring the wizard's shared modal:

```erb
<dialog id="<%= dialog_id %>"
        class="modal"
        data-controller="shared-modal"
        data-action="turbo:frame-load->shared-modal#open">
  <div class="modal-box max-w-2xl overflow-visible">
    <%= helpers.turbo_frame_tag frame_id do %>
      <div class="flex justify-center py-8">
        <span class="loading loading-spinner loading-lg"></span>
      </div>
    <% end %>
  </div>
  <form method="dialog" class="modal-backdrop">
    <button>close</button>
  </form>
</dialog>
```

`overflow-visible` on the modal-box is load-bearing — the autocomplete dropdown must escape the box.

- [ ] **Step 5: Write the form component**

`app/components/admin/edit_list_item_form_component.rb` — move the five helper methods over from the old component verbatim:

```ruby
# frozen_string_literal: true

class Admin::EditListItemFormComponent < ViewComponent::Base
  def initialize(list_item:)
    @list_item = list_item
    @list = list_item.list
    @config = Admin::DomainRouting.list_config(@list) || {}
  end

  def autocomplete_url
    @config[:autocomplete_path]
  end

  def item_label
    @config.fetch(:item_label, "Item")
  end

  def item_display_name
    return unverified_item_display_name if @list_item.listable.nil?

    if @list_item.listable.respond_to?(:title)
      @list_item.listable.title
    elsif @list_item.listable.respond_to?(:name)
      @list_item.listable.name
    else
      "#{@list_item.listable.class.name} ##{@list_item.listable.id}"
    end
  end

  def unverified_item_display_name
    if @list_item.metadata.present?
      @list_item.metadata["title"] || @list_item.metadata["name"] || "Unverified Item ##{@list_item.position}"
    else
      "Unverified Item ##{@list_item.position}"
    end
  end

  def metadata_json
    return "" if @list_item.metadata.blank?
    JSON.pretty_generate(@list_item.metadata)
  end
end
```

Its template is the **body** of the old modal template — everything that was inside `<div class="modal-box">`, now wrapped in the shared frame instead of a dialog. Copy the old template's form verbatim and change only what's listed below:

```erb
<%= turbo_frame_tag Admin::EditListItemModalComponent::FRAME_ID do %>
  <h3 class="font-bold text-lg">Edit List Item</h3>
  <%= form_with model: @list_item,
                url: admin_list_item_path(@list_item),
                method: :patch,
                class: "space-y-4",
                data: {
                  controller: "modal-form",
                  modal_form_modal_id_value: Admin::EditListItemModalComponent::DIALOG_ID,
                  turbo_frame: "list_items_list"
                } do |f| %>
    <%# ... the autocomplete / position / metadata / verified fields, copied verbatim ... %>

    <div class="modal-action">
      <button type="button" class="btn" onclick="<%= Admin::EditListItemModalComponent::DIALOG_ID %>.close()">Cancel</button>
      <%= f.submit "Update Item", class: "btn btn-primary" %>
    </div>
  <% end %>
<% end %>
```

The three changes from the old template: the outer wrapper is the shared **frame** rather than a per-item `<dialog>`; `modal_form_modal_id_value` is now the **constant** `DIALOG_ID` instead of `"edit_list_item_modal_dialog_#{id}"`; and the Cancel button's `onclick` closes that constant dialog. `modal_form_controller.js` closes the dialog by that id on a successful submit, so the id must match exactly.

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/components/admin/`
Expected: PASS, 0 failures.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/components/admin/ test/components/admin/
git add app/components/admin/ test/components/admin/
git commit -m "Split the list-item edit modal into a shell and an on-demand form"
```

---

### Task 2: Serve the form on demand, and render one shell per page

**Files:**
- Modify: `config/routes.rb` (add `:edit` to the shallow `resources :list_items`)
- Modify: `app/controllers/admin/list_items_controller.rb` (add `edit`)
- Modify: `app/views/admin/list_items/index.html.erb` (Edit button → frame-targeting link; delete the per-row modal loop)
- Modify: `app/components/admin/lists/show_component.html.erb` (render the shell once)
- Test: `test/controllers/admin/list_items_controller_test.rb`

**Interfaces:**
- Consumes: `Admin::EditListItemModalComponent::FRAME_ID` and `Admin::EditListItemFormComponent` from Task 1.
- Produces: `GET /admin/list_items/:id/edit` → `admin_edit_list_item_path(list_item)`, rendering `Admin::EditListItemFormComponent` with `layout: false`.

- [ ] **Step 1: Write the failing controller test**

Append to `test/controllers/admin/list_items_controller_test.rb` (read it first — match its `setup`, fixtures, and `sign_in_as(@user, stub_auth: true)`):

```ruby
test "edit renders the form for the shared modal frame" do
  get edit_admin_list_item_path(@list_item)

  assert_response :success
  assert_select "turbo-frame##{Admin::EditListItemModalComponent::FRAME_ID}"
end
```

- [ ] **Step 2: Run it and see it fail**

Run: `bin/rails test test/controllers/admin/list_items_controller_test.rb`
Expected: FAIL — `NameError: undefined local variable or method 'edit_admin_list_item_path'` (no route).

- [ ] **Step 3: Add the route**

`config/routes.rb` — the shallow member routes for list items, currently:
```ruby
resources :list_items, only: [:update, :destroy]
```
becomes:
```ruby
resources :list_items, only: [:edit, :update, :destroy]
```
Do **not** touch the nested `scope "list/:list_id"` block's `resources :list_items, only: [:index, :create]`.

- [ ] **Step 4: Add the `edit` action**

In `app/controllers/admin/list_items_controller.rb`, add `:edit` to the `set_list_item` before_action, and the action itself:

```ruby
before_action :set_list_item, only: [:edit, :update, :destroy]

def edit
  render Admin::EditListItemFormComponent.new(list_item: @list_item), layout: false
end
```

`authenticate_admin!` already resolves the domain from `ListItem.find_by(id: params[:id])&.list` for member routes, so `edit` is authorized exactly like `update` and `destroy` — no auth change needed.

- [ ] **Step 5: Point the Edit button at the frame, and delete the per-row modals**

In `app/views/admin/list_items/index.html.erb`, replace the `<button ... onclick="edit_list_item_modal_dialog_<%= list_item.id %>.showModal()">` with a link that targets the shared frame, keeping the same pencil SVG and the same `btn btn-primary btn-xs join-item` classes so the row's button group looks unchanged:

```erb
<%= link_to edit_admin_list_item_path(list_item),
    class: "btn btn-primary btn-xs join-item",
    data: {turbo_frame: Admin::EditListItemModalComponent::FRAME_ID} do %>
  <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
    <path d="M13.586 3.586a2 2 0 112.828 2.828l-.793.793-2.828-2.828.793-.793zM11.379 5.793L3 14.172V17h2.828l8.38-8.379-2.83-2.828z" />
  </svg>
<% end %>
```

Then **delete** the per-row modal loop entirely (currently lines 78-81):
```erb
<%# Render edit modals for each list item %>
<% list_items.each do |list_item| %>
  <%= render Admin::EditListItemModalComponent.new(list_item: list_item) %>
<% end %>
```

- [ ] **Step 6: Render the shell once on the list show page**

In `app/components/admin/lists/show_component.html.erb`, render the shell exactly once. Put it next to where the other page-level modals are rendered (search the file for `add_item_to_list_modal_dialog` / `attach_penalty_modal` to find where they live) — **not** inside the `list_items_list` frame, or it would be replaced on every frame update and there would again be one per re-render:

```erb
<%= render Admin::EditListItemModalComponent.new %>
```

- [ ] **Step 7: Run the tests**

Run: `bin/rails test test/controllers/admin/ test/components/admin/`
Expected: PASS, 0 failures.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix app/ config/routes.rb test/
git add app/ config/routes.rb test/
git commit -m "Load the list-item edit form on demand into a single modal"
```

---

### Task 3: Paginate the list items

**Files:**
- Modify: `app/controllers/admin/list_items_controller.rb` (`index`, and the `create` / `update` / `destroy` turbo_stream re-renders)
- Modify: `app/views/admin/list_items/index.html.erb` (pagination nav)
- Test: `test/controllers/admin/list_items_controller_test.rb`

**Interfaces:**
- Produces: `Admin::ListItemsController#index` sets `@pagy` and a paginated `@list_items`. The index template renders `@pagy.series_nav` when there is more than one page.

**The trap:** `create`, `update`, and `destroy` each re-render the index template inside a `turbo_stream.replace`, passing `list_items: @list.list_items.includes(:listable).order(:position)` — an **unpaginated** relation. If you only fix `index`, pagination silently reverts to "all 6,933 items" the moment anyone adds, edits, or deletes an item. All four must go through the same loader.

- [ ] **Step 1: Write the failing test**

**`assigns()` is NOT available** — `rails-controller-testing` is not in the Gemfile and no existing controller test uses it. Assert on the rendered response instead.

Append to `test/controllers/admin/list_items_controller_test.rb`. Build enough items to exceed one page, then assert page 1 is truncated and page 2 exists:

```ruby
test "index paginates list items" do
  list = lists(:music_albums_list)
  album = music_albums(:dark_side_of_the_moon)
  60.times { |i| list.list_items.create!(listable: album, position: 100 + i) }

  get admin_list_list_items_path(list)

  assert_response :success
  assert_select "tbody tr", count: 50

  get admin_list_list_items_path(list, page: 2)

  assert_response :success
  assert_select "tbody tr", minimum: 1
end
```

`list_items` has a `listable` uniqueness constraint in some domains — if `create!` raises on the duplicate album, vary the listable (use several album fixtures) or drop the constraint check by using distinct albums. Read `app/models/list_item.rb` first and adapt; the point of the test is "page 1 has exactly `limit` rows and page 2 is reachable," not the specific records.

This asserts markup (`tbody tr`), which the project's testing guide normally forbids for controller tests. It is justified here and **only** here: row *count* is the behavior under test, and there is no other observable. Do not assert on any CSS class, copy, or column content.

- [ ] **Step 2: Run it and see it fail**

Run: `bin/rails test test/controllers/admin/list_items_controller_test.rb`
Expected: FAIL — `@pagy` is nil, because `index` does not paginate.

- [ ] **Step 3: Paginate, through one shared loader**

In `app/controllers/admin/list_items_controller.rb`, add a private loader and route all four renders through it:

```ruby
def load_list_items
  @pagy, @list_items = pagy(
    @list.list_items.includes(:listable).order(:position),
    limit: 50
  )
end
```

`index` becomes:

```ruby
def index
  load_list_items
  render layout: false
end
```

Then in `create`, `update`, and `destroy`, call `load_list_items` after the `@list.reload` and change each `turbo_stream.replace("list_items_list", ...)` to pass the paginated collection and the pagy object:

```ruby
turbo_stream.replace(
  "list_items_list",
  template: "admin/list_items/index",
  locals: {list: @list, list_items: @list_items, pagy: @pagy}
)
```

`pagy` is already available — `Admin::BaseController` includes `Pagy::Method`.

- [ ] **Step 4: Render the pagination nav**

In `app/views/admin/list_items/index.html.erb`, pick up `pagy` from locals alongside the existing `list` and `list_items` (line 2-3 already use `local_assigns.fetch`):

```erb
<% pagy = local_assigns.fetch(:pagy, @pagy) %>
```

Then, immediately after the closing `</div>` of the `overflow-x-auto` table wrapper and before the `<% else %>`, add the nav — copied from the `ranked_lists` precedent, with the anchor string pointed at **this** frame:

```erb
<% if pagy && pagy.pages > 1 %>
  <div class="flex justify-center py-4 border-t border-base-300">
    <%== pagy.series_nav(anchor_string: 'data-turbo-frame="list_items_list"') %>
  </div>
<% end %>
```

Note `<%==` — raw output. `series_nav` returns HTML and will be escaped into visible markup if you use `<%=`. The `anchor_string` is what keeps the page links inside the Turbo Frame instead of navigating the whole page; without it, clicking page 2 blows away the list show page.

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/controllers/admin/`
Expected: PASS, 0 failures.

- [ ] **Step 6: Verify the pagination links actually stay in the frame**

This is the part a controller test cannot prove. With the dev server running, open a music album list's admin show page that has more than 50 items, click page 2, and confirm the table updates **in place** — the surrounding list show page (its header, penalties panel, etc.) must not be replaced, and the URL must not change to `/admin/list/:id/list_items?page=2`.

If no music/games list has more than 50 items, temporarily lower the `limit:` to 5, verify, then set it back to 50 and re-run the tests. Report which you did.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/ test/
git add app/ test/
git commit -m "Paginate admin list items"
```

---

### Task 4: End-to-end coverage

The two behavior changes — the edit modal now loads on demand, and the table paginates — are exactly the kind that pass a controller test and break in a browser. Turbo Frame wiring, the `turbo:frame-load` → `showModal()` handshake, and the frame-scoped pagination links are all client-side.

**Files:**
- Create: `e2e/tests/music/admin/list-items-modal.spec.ts`
- Test: the existing `e2e/tests/music/admin/album-lists-sorting.spec.ts` is the closest sibling — read it for the page-object and navigation conventions.

- [ ] **Step 1: Confirm the e2e suite is green before you start**

Run: `yarn test:e2e --grep "Album Lists"`
Expected: PASS. If admin specs fail with click timeouts on the public homepage, the e2e user lost its role in a dev-DB reseed — run `bin/rails e2e:admin` and retry. That is an environment fix, not a code bug.

- [ ] **Step 2: Write the spec**

Cover the two things only a browser can prove:

1. **Exactly one dialog exists on the page**, not one per row — this is the whole point of the increment:
   ```ts
   await expect(page.locator('dialog#edit_list_item_modal_dialog')).toHaveCount(1);
   ```
2. **Clicking Edit loads the form on demand and opens the modal** — the form is absent before the click, present after:
   ```ts
   await expect(page.locator('#edit_list_item_modal_content form')).toHaveCount(0);
   await firstRowEditButton.click();
   await expect(page.locator('dialog#edit_list_item_modal_dialog')).toBeVisible();
   await expect(page.locator('#edit_list_item_modal_content form')).toBeVisible();
   ```
3. **Editing still works end to end** — change the position, submit, confirm the dialog closes and the table reflects the new value.

Navigate to an admin album list show page that has items. Find a real one from the fixtures/dev data rather than hardcoding an id that may not exist — follow how `album-lists-sorting.spec.ts` gets there.

Add `data-testid` (kebab-case) **only** where role/text/label cannot target an element.

- [ ] **Step 3: Run it**

Run: `yarn test:e2e --grep "list items"` (match whatever `test.describe` name you chose)
Expected: PASS.

- [ ] **Step 4: Run the whole e2e suite for regressions**

Run: `yarn test:e2e`
Expected: 157+ passed, 0 failed. The suite was 156/156 before this increment; you are adding specs, not changing existing ones. **If an existing spec now fails, you broke it — fix the code, not the spec.**

- [ ] **Step 5: Full verification and commit**

```bash
bin/rails test && bundle exec standardrb
git add e2e/
git commit -m "Add e2e coverage for the single-instance list-item modal"
```

---

## Done when

- `bin/rails test` — green (4,565+ tests).
- `bundle exec standardrb` — clean.
- `yarn test:e2e` — green, 157+ passing.
- `grep -c "EditListItemModalComponent.new" app/views/admin/list_items/index.html.erb` — returns **0**. The per-row loop is gone.
- Loading a list show page emits exactly **one** `<dialog id="edit_list_item_modal_dialog">`, regardless of item count.
- `Admin::ListItemsController` paginates in `index` **and** in the `create` / `update` / `destroy` turbo_stream re-renders — all four via `load_list_items`.
