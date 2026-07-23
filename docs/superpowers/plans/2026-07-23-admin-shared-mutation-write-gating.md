# Admin shared-mutation write-gating — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A domain *viewer* can no longer mutate list items, list penalties, ranked lists, or penalty applications — across all domains — while reads and editor/admin writes are unchanged.

**Architecture:** Gate every mutating action on the four shared controllers on domain **write** via `Admin::DomainScopedAuth#require_domain_write!` (added in 6a). The two RC-based controllers already use the concern; the two list controllers migrate their duplicated hand-rolled string-split auth into it. Then guard the corresponding Add/clear/destroy/edit affordances in the views on `current_user_can_write?`.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, ViewComponent, DaisyUI 5.

## Global Constraints

- Run all commands from `web-app/`. Lint with `bundle exec standardrb` (NOT rubocop).
- Controller tests assert **behavior only** (status, redirect, record deltas) — never HTML/CSS/copy.
- Auth in integration tests: `sign_in_as(user, stub_auth: true)`. Fixtures are semantic: `contractor_user` is a **music editor** (`music_editor` domain_roles fixture) + games viewer; `regular_user` has no global role; `admin_user` is a global admin. Give `regular_user` an in-test role with `regular_user.domain_roles.create!(domain: :music, permission_level: :viewer)`.
- All mutations gate on **write** (`can_write_in_domain?`), not delete — including `destroy_all`/`clear_positions` (WG-1). Global admin/editor bypass is built into `require_domain_write!`.
- The list controllers keep their **string-split** domain resolution, moved into `domain_for_auth` (WG-3) — do NOT route it through the `DomainRouting` registry.
- The controller gate is the security boundary; the view guards (Task 3) are UX + defense-in-depth.
- `raise_on_missing_callback_actions` is ON — every action named in a `before_action only: [...]` must exist.
- Verify with `bin/rails test` + `bundle exec standardrb`. Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Branch `admin-write-gating` (already created off main).

---

### Task 1: Write-gate the RC-based controllers (`ranked_lists`, `penalty_applications`)

Both already `include Admin::DomainScopedAuth` and override `domain_for_auth` to resolve the ranking configuration's domain. Adding `require_domain_write!` reuses that resolution, now checking write.

**Files:**
- Modify: `web-app/app/controllers/admin/ranked_lists_controller.rb`
- Modify: `web-app/app/controllers/admin/penalty_applications_controller.rb`
- Test: `web-app/test/controllers/admin/ranked_lists_controller_test.rb`
- Test: `web-app/test/controllers/admin/penalty_applications_controller_test.rb`

**Interfaces:**
- Consumes: `Admin::DomainScopedAuth#require_domain_write!` (checks `can_write_in_domain?(domain_for_auth)`, global admin/editor bypass, redirect to `domain_root_path`).

- [ ] **Step 1: Write the failing tests (ranked_lists)**

Add to `Admin::RankedListsControllerTest` (music host; setup signs in as admin — these re-sign):

```ruby
    test "denies a music domain viewer from creating a ranked list" do
      @regular_user.domain_roles.create!(domain: :music, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)

      assert_no_difference "RankedList.count" do
        post admin_ranking_configuration_ranked_lists_path(@album_config),
          params: {ranked_list: {list_id: @album_list.id}}, as: :turbo_stream
      end
      assert_redirected_to music_root_path
    end

    test "denies a music domain viewer from destroying a ranked list" do
      ranked_list = RankedList.create!(ranking_configuration: @album_config, list: @album_list, weight: 50)
      @regular_user.domain_roles.create!(domain: :music, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)

      assert_no_difference "RankedList.count" do
        delete admin_ranked_list_path(ranked_list), as: :turbo_stream
      end
      assert_redirected_to music_root_path
    end

    test "allows a music domain editor to create a ranked list" do
      sign_in_as(users(:contractor_user), stub_auth: true) # music editor

      assert_difference "RankedList.count", 1 do
        post admin_ranking_configuration_ranked_lists_path(@album_config),
          params: {ranked_list: {list_id: @album_list.id}}, as: :turbo_stream
      end
      assert_response :success
    end
```

- [ ] **Step 2: Write the failing tests (penalty_applications)**

Add to `Admin::PenaltyApplicationsControllerTest`:

```ruby
    test "denies a music domain viewer from creating a penalty application" do
      @regular_user.domain_roles.create!(domain: :music, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)

      assert_no_difference "PenaltyApplication.count" do
        post admin_ranking_configuration_penalty_applications_path(@album_config),
          params: {penalty_application: {penalty_id: @global_penalty.id, value: 75}}, as: :turbo_stream
      end
      assert_redirected_to music_root_path
    end

    test "denies a music domain viewer from updating a penalty application" do
      pa = PenaltyApplication.create!(ranking_configuration: @album_config, penalty: @global_penalty, value: 75)
      @regular_user.domain_roles.create!(domain: :music, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)

      patch admin_penalty_application_path(pa), params: {penalty_application: {value: 40}}, as: :turbo_stream
      assert_redirected_to music_root_path
      assert_equal 75, pa.reload.value
    end

    test "denies a music domain viewer from destroying a penalty application" do
      pa = PenaltyApplication.create!(ranking_configuration: @album_config, penalty: @global_penalty, value: 75)
      @regular_user.domain_roles.create!(domain: :music, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)

      assert_no_difference "PenaltyApplication.count" do
        delete admin_penalty_application_path(pa), as: :turbo_stream
      end
      assert_redirected_to music_root_path
    end

    test "allows a music domain editor to create a penalty application" do
      sign_in_as(users(:contractor_user), stub_auth: true) # music editor

      assert_difference "PenaltyApplication.count", 1 do
        post admin_ranking_configuration_penalty_applications_path(@album_config),
          params: {penalty_application: {penalty_id: @global_penalty.id, value: 75}}, as: :turbo_stream
      end
      assert_response :success
    end
```

- [ ] **Step 3: Run to verify failures**

Run: `bin/rails test test/controllers/admin/ranked_lists_controller_test.rb test/controllers/admin/penalty_applications_controller_test.rb -n "/domain viewer|domain editor/"`
Expected: the "denies … viewer" tests FAIL (the mutation currently succeeds — a viewer can write today).

- [ ] **Step 4: Add the write gate**

In `web-app/app/controllers/admin/ranked_lists_controller.rb`, add after the existing `before_action` lines (line 5-ish):
```ruby
  before_action :require_domain_write!, only: [:create, :destroy]
```

In `web-app/app/controllers/admin/penalty_applications_controller.rb`, add after the existing `before_action` lines:
```ruby
  before_action :require_domain_write!, only: [:create, :update, :destroy]
```

- [ ] **Step 5: Run to verify green**

Run: `bin/rails test test/controllers/admin/ranked_lists_controller_test.rb test/controllers/admin/penalty_applications_controller_test.rb`
Expected: PASS (all, including the pre-existing admin/read tests).

- [ ] **Step 6: standardrb + commit**

Run: `bundle exec standardrb app/controllers/admin/ranked_lists_controller.rb app/controllers/admin/penalty_applications_controller.rb test/controllers/admin/ranked_lists_controller_test.rb test/controllers/admin/penalty_applications_controller_test.rb` → no offenses.

```bash
git add app/controllers/admin/ranked_lists_controller.rb app/controllers/admin/penalty_applications_controller.rb test/controllers/admin/ranked_lists_controller_test.rb test/controllers/admin/penalty_applications_controller_test.rb
git commit -m "$(cat <<'EOF'
Gate ranked-list + penalty-application mutations on domain write

Both controllers already resolve the RC's domain via DomainScopedAuth;
add require_domain_write! so domain viewers can no longer create/update/
destroy them. Reads unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Migrate the list controllers onto `DomainScopedAuth` + write-gate (`list_items`, `list_penalties`)

Both hand-roll a byte-identical string-split `authenticate_admin!`. Replace it with `DomainScopedAuth` (behavior-preserving access check) driven by a `domain_for_auth` that keeps the string-split, then add the write gate.

**Files:**
- Modify: `web-app/app/controllers/admin/list_items_controller.rb`
- Modify: `web-app/app/controllers/admin/list_penalties_controller.rb`
- Test: `web-app/test/controllers/admin/list_items_controller_test.rb`
- Test: `web-app/test/controllers/admin/list_penalties_controller_test.rb`

**Interfaces:**
- Consumes: `Admin::DomainScopedAuth` (`authenticate_admin!` = `can_access_domain?(domain_for_auth)`; `require_domain_write!` = `can_write_in_domain?(domain_for_auth)`).
- Produces: each controller overrides `domain_for_auth` → the list's domain via `list.type.split("::").first.downcase`.

- [ ] **Step 1: Write the failing tests (list_items)**

Add to `Admin::ListItemsControllerTest` (music host):

```ruby
    test "denies a music domain viewer from creating a list item" do
      @regular_user.domain_roles.create!(domain: :music, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)

      assert_no_difference "ListItem.count" do
        post admin_list_list_items_path(@album_list),
          params: {list_item: {listable_id: @album.id, listable_type: "Music::Album", position: 1}}, as: :turbo_stream
      end
      assert_redirected_to music_root_path
    end

    test "denies a music domain viewer from destroying a list item" do
      list_item = ListItem.create!(list: @album_list, listable: @album, position: 1, verified: true)
      @regular_user.domain_roles.create!(domain: :music, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)

      assert_no_difference "ListItem.count" do
        delete admin_list_item_path(list_item), as: :turbo_stream
      end
      assert_redirected_to music_root_path
    end

    test "denies a music domain viewer from clearing positions" do
      ListItem.create!(list: @album_list, listable: @album, position: 1, verified: true)
      @regular_user.domain_roles.create!(domain: :music, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)

      post clear_positions_admin_list_list_items_path(@album_list), as: :turbo_stream
      assert_redirected_to music_root_path
    end

    test "allows a music domain editor to create a list item" do
      sign_in_as(users(:contractor_user), stub_auth: true) # music editor

      assert_difference "ListItem.count", 1 do
        post admin_list_list_items_path(@album_list),
          params: {list_item: {listable_id: @album.id, listable_type: "Music::Album", position: 1}}, as: :turbo_stream
      end
      assert_response :success
    end

    test "still allows a music domain viewer to read the list items (access unchanged)" do
      ListItem.create!(list: @album_list, listable: @album, position: 1, verified: true)
      @regular_user.domain_roles.create!(domain: :music, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)

      get admin_list_list_items_path(@album_list)
      assert_response :success
    end
```

- [ ] **Step 2: Write the failing tests (list_penalties)**

Add to `Admin::ListPenaltiesControllerTest`:

```ruby
    test "denies a music domain viewer from attaching a list penalty" do
      @regular_user.domain_roles.create!(domain: :music, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)

      assert_no_difference "ListPenalty.count" do
        post admin_list_list_penalties_path(@album_list),
          params: {list_penalty: {penalty_id: @global_penalty.id}}, as: :turbo_stream
      end
      assert_redirected_to music_root_path
    end

    test "denies a music domain viewer from detaching a list penalty" do
      list_penalty = ListPenalty.create!(list: @album_list, penalty: @global_penalty)
      @regular_user.domain_roles.create!(domain: :music, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)

      assert_no_difference "ListPenalty.count" do
        delete admin_list_penalty_path(list_penalty), as: :turbo_stream
      end
      assert_redirected_to music_root_path
    end

    test "allows a music domain editor to attach a list penalty" do
      sign_in_as(users(:contractor_user), stub_auth: true) # music editor

      assert_difference "ListPenalty.count", 1 do
        post admin_list_list_penalties_path(@album_list),
          params: {list_penalty: {penalty_id: @global_penalty.id}}, as: :turbo_stream
      end
      assert_response :success
    end

    test "still allows a music domain viewer to read the list penalties (access unchanged)" do
      ListPenalty.create!(list: @album_list, penalty: @global_penalty)
      @regular_user.domain_roles.create!(domain: :music, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)

      get admin_list_list_penalties_path(@album_list)
      assert_response :success
    end
```

- [ ] **Step 3: Run to verify failures**

Run: `bin/rails test test/controllers/admin/list_items_controller_test.rb test/controllers/admin/list_penalties_controller_test.rb -n "/domain viewer|domain editor/"`
Expected: the "denies … viewer" mutation tests FAIL (a viewer can write today); the "read" and "editor" tests already pass.

- [ ] **Step 4: Migrate `ListItemsController`**

In `web-app/app/controllers/admin/list_items_controller.rb`, add the include as the first line of the class body and the write gate, then **replace** the hand-rolled `authenticate_admin!` (currently in `private`, ~lines 7-22) with a `domain_for_auth` override:

Class header:
```ruby
class Admin::ListItemsController < Admin::BaseController
  include Admin::DomainScopedAuth

  before_action :require_domain_write!, only: [:create, :update, :destroy, :destroy_all, :clear_positions]
  before_action :set_list, only: [:index, :create, :destroy_all, :clear_positions]
  before_action :set_list_item, only: [:edit, :update, :destroy]
```

Replace the `authenticate_admin!` method (the whole `# Override to allow …` comment + method) with:
```ruby
  def domain_for_auth
    list = if params[:list_id].present?
      List.find_by(id: params[:list_id])
    elsif params[:id].present?
      ListItem.find_by(id: params[:id])&.list
    end
    list&.type&.split("::")&.first&.downcase
  end
```

- [ ] **Step 5: Migrate `ListPenaltiesController`**

Same change in `web-app/app/controllers/admin/list_penalties_controller.rb`:

Class header:
```ruby
class Admin::ListPenaltiesController < Admin::BaseController
  include Admin::DomainScopedAuth

  before_action :require_domain_write!, only: [:create, :destroy]
  before_action :set_list, only: [:index, :create]
  before_action :set_list_penalty, only: [:destroy]
```

Replace its hand-rolled `authenticate_admin!` with (note `ListPenalty` for the shallow lookup):
```ruby
  def domain_for_auth
    list = if params[:list_id].present?
      List.find_by(id: params[:list_id])
    elsif params[:id].present?
      ListPenalty.find_by(id: params[:id])&.list
    end
    list&.type&.split("::")&.first&.downcase
  end
```

- [ ] **Step 6: Run to verify green**

Run: `bin/rails test test/controllers/admin/list_items_controller_test.rb test/controllers/admin/list_penalties_controller_test.rb`
Expected: PASS (all — the new viewer-denied + editor-allowed + read-access tests, and every pre-existing test, confirming the auth migration is behavior-preserving for reads and admin/editor writes).

- [ ] **Step 7: standardrb + commit**

Run: `bundle exec standardrb app/controllers/admin/list_items_controller.rb app/controllers/admin/list_penalties_controller.rb test/controllers/admin/list_items_controller_test.rb test/controllers/admin/list_penalties_controller_test.rb` → no offenses.

```bash
git add app/controllers/admin/list_items_controller.rb app/controllers/admin/list_penalties_controller.rb test/controllers/admin/list_items_controller_test.rb test/controllers/admin/list_penalties_controller_test.rb
git commit -m "$(cat <<'EOF'
Gate list-item + list-penalty mutations on domain write

Migrate the two controllers' duplicated hand-rolled string-split auth onto
DomainScopedAuth (behavior-preserving access check via domain_for_auth) and
add require_domain_write! on the mutations, so domain viewers can no longer
create/update/destroy/clear list items or attach/detach list penalties.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Guard the mutation affordances in the views

Hide the Add/clear/destroy/edit affordances from viewers (defense-in-depth + UX). Wrap each in `current_user_can_write?` (ERB) / `helpers.current_user_can_write?` (`ShowComponent`). The controller gate already blocks the actions; this stops rendering buttons a viewer can't use.

**Files:**
- Modify: `web-app/app/components/admin/lists/show_component.html.erb`
- Modify: `web-app/app/views/admin/list_items/index.html.erb`
- Modify: `web-app/app/views/admin/ranking_configurations/show.html.erb`
- Modify: `web-app/app/views/admin/penalty_applications/index.html.erb`
- Modify: `web-app/app/views/admin/ranked_lists/index.html.erb`
- Modify: `web-app/app/views/admin/ranked_lists/show.html.erb`
- Test: `web-app/test/controllers/admin/books/lists_controller_test.rb` (a viewer render-check)

**Affordances to wrap** (each in `<% if [helpers.]current_user_can_write? %> … <% end %>`):
- `show_component.html.erb`: "Clear positions" (`clear_positions`, ~L234), "Destroy all" (`destroy_all`, ~L240), "+ Add item" trigger (~L247), "Attach penalty" trigger (~L268), and the `render Admin::AddItemToListModalComponent` (~L341) + `render Admin::EditListItemModalComponent` (~L343) + the attach-penalty modal render. Use `helpers.current_user_can_write?`. (Leave the Research-Prompt button (L22) and the list-level `button_to` (L51) — those are not list-item/penalty mutations.)
- `list_items/index.html.erb`: the edit trigger (~L60) and the destroy `button_to` (~L65).
- `ranking_configurations/show.html.erb`: "+ Add penalty to configuration" trigger (~L236) + its modal render, "+ Add list to configuration" trigger (~L286), and `render Admin::AddListToConfigurationModalComponent` (~L366). (Leave Recalculate Weights / Refresh Rankings / delete-RC at L48/55/66 — those are RC-level, gated by the RC controller.)
- `penalty_applications/index.html.erb`: the edit trigger (~L57), the destroy `button_to` (~L62), and the `render Admin::EditPenaltyApplicationModalComponent` (~L80).
- `ranked_lists/index.html.erb`: the "Delete" `button_to` (~L57).
- `ranked_lists/show.html.erb`: the "Remove List" `button_to` (~L201).

- [ ] **Step 1: Add the guards**

Wrap each affordance listed above in the presence guard. For the `ShowComponent`, use `helpers.current_user_can_write?`; for the ERB views, `current_user_can_write?`. Do not alter the surrounding markup or the non-mutation elements.

- [ ] **Step 2: Write a viewer render-check test**

Add to `Admin::Books::ListsControllerTest` (books host — a books list show page renders the `ShowComponent` with the guards):

```ruby
    test "list show renders for a books domain viewer without error" do
      @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)
      get admin_books_list_path(@list)
      assert_response :success
    end
```

(Behavior-only: confirms the guarded template renders cleanly for a viewer. Button-hiding correctness is verified by the reviewer reading the guard placement; the controller gate in Tasks 1-2 is the security boundary.)

- [ ] **Step 3: Run the render-check + the admin/editor suites still green**

Run: `bin/rails test test/controllers/admin/books/lists_controller_test.rb test/controllers/admin/ranking_configurations_controller_test.rb`
Expected: PASS (guards don't break rendering for viewers or admins).

- [ ] **Step 4: standardrb + commit**

Run: `bundle exec standardrb app/components/admin/lists/show_component.html.erb test/controllers/admin/books/lists_controller_test.rb` (standardrb skips `.erb`; run it on the Ruby test file — the ERB views are checked by the app booting in the test run).
Expected: no offenses.

```bash
git add app/components/admin/lists/show_component.html.erb app/views/admin/list_items/index.html.erb app/views/admin/ranking_configurations/show.html.erb app/views/admin/penalty_applications/index.html.erb app/views/admin/ranked_lists/index.html.erb app/views/admin/ranked_lists/show.html.erb test/controllers/admin/books/lists_controller_test.rb
git commit -m "$(cat <<'EOF'
Guard admin mutation buttons on domain write

Hide the Add/clear/destroy/edit affordances for list items, list penalties,
ranked lists, and penalty applications from domain viewers (current_user_can_write?).
Defense-in-depth over the controller write gate.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] `bin/rails test` — full suite green (baseline ~4836/0 on main; expect that plus the new tests).
- [ ] `bundle exec standardrb` — no offenses.
- [ ] Confirm no existing test's assertion was weakened. The only existing-test edits should be additive (new tests appended); if a pre-existing assertion changed, stop and investigate.
- [ ] Spot-check the migration is behavior-preserving: the list controllers' pre-existing admin/editor create/update/destroy tests still pass unchanged (proves the `authenticate_admin!` → `DomainScopedAuth` swap didn't regress access).

## Notes

- The security boundary is the controller `require_domain_write!` gate (Tasks 1-2). Task 3's view guards are UX + defense-in-depth; a missed button renders a 302 on submit, not a data mutation.
- `require_domain_write!` and the concern's `authenticate_admin!` both redirect to `domain_root_path` (music host → `music_root_path`), which the tests assert.
- This closes the viewer-write gap Codex flagged as P1 on #174 and #175. `ranked_items` (read-only) and the already-gated `images`/`category_items` (6a) are out of scope.
