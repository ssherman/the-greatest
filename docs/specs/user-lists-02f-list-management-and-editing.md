# User Lists — Part 2 (Phase B): List Management & Editing

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2026-06-05
- **Developer**: Shane Sherman (with Claude Code)

## Overview
Add the **write/management** surface on top of the Phase A read-only My Lists pages: **create** a custom list from the dashboard, a **separate drag-and-drop edit page** (SortableJS) to **reorder** items, **remove** items, and edit list **metadata** (name / description / public) — all saved together in one transactional `PATCH` — **delete** a custom list, and **inline `completed_on` editing** on the show page for completion-type lists.

This is **Phase B**, built directly on `docs/specs/completed/user-lists-02-ui-and-cached-page-integration.md` (Phase A). Read Phase A first — its "Pre-agreed design decisions" (global controller + `Current.domain` + dynamic layout, never-cached pages with standard meta-CSRF, owner-only, per-subclass `completed_on_list_types`) and its models/components/routes are prerequisites and are not repeated here except where extended.

### Non-goals (Phase B)
- Anything in Phase A (dashboard, show, view modes, sort, CSV, nav link).
- Adding an item from within a list page (autocomplete) → `user-lists-02e`.
- Public discovery / viewing other users' lists, "consumed" badges → `02d`.
- List-level reordering / `user_lists.position` → future.
- Cross-page drag reorder (the edit page is intentionally unpaginated — see Behaviors).

## Context & Links
- **Prerequisite:** `docs/specs/completed/user-lists-02-ui-and-cached-page-integration.md` (Phase A) — must ship first.
- Predecessors: `docs/specs/completed/user-lists-01-data-model.md`, `docs/specs/completed/user-lists-02a-add-to-list-widget.md`
- Old-site reference (SortableJS edit page): `docs/old_site/user-lists-feature.md`; concrete controller: `../the-greatest-books/admin/app/javascript/controllers/user_list_sort_controller.js`
- Authoritative source files:
  - `web-app/app/models/user_list.rb` (`reorder_items!`, `default?`), `web-app/app/models/user_list_item.rb` (`completed_on`, `set_position`, `after_destroy_commit :shift_positions_up`)
  - `web-app/app/controllers/my_lists_controller.rb` (created in Phase A — extended here)
  - `web-app/app/controllers/user_list_items_controller.rb` (02a — extended here), `web-app/app/controllers/concerns/json_error_responses.rb`
  - `web-app/app/policies/{user_list_policy,user_list_item_policy}.rb`
  - `web-app/app/components/user_lists/show/item_component.rb` (created in Phase A — editor added here)
  - `web-app/rollup.config.js`, `web-app/package.json` (add `sortablejs`)

## Pre-agreed design decisions (Phase B specifics)
1. **Separate edit page, batch save.** The show page stays read-only. Reorder (drag), remove, and metadata edits all happen on `/my/lists/:id/edit` and save together in one transactional `PATCH` (old-app pattern).
2. **`completed_on` editing is inline on the show page** (a small JSON `PATCH` with optimistic UI + toast), *not* batched into the edit page — it's a single per-item field and forcing a full edit-save for one date is poor UX.
3. **Custom lists are deletable; default lists are not.** `destroy?` ⇒ `owner? && !record.default?`.
4. **Default lists may be renamed.** Editing `name`/`description`/`public` is allowed on all owned lists (only `list_type` is immutable, via the existing `list_type_immutable` validation).
5. **Standard meta-CSRF** is valid (these pages are never cached) — do **not** route the token through `/user_list_state` (that 02a workaround was only for cached pages).
6. **Widget state staleness is self-healing.** Mutations bump `user.updated_at` via the existing `after_commit :touch_user`; the 02a `user-list-state` controller re-fetches `/user_list_state` on the next page `connect()`. Do **not** add imperative localStorage poking after mutations.

---

## Interfaces & Contracts

### Domain Model (diffs only)
No migration. Phase A already added `completed_on_list_types`/`completed_on_enabled?`. Phase B relies on the existing `reorder_items!(ordered_listable_ids)` (validates the ordered set exactly matches current items) and `default?` (custom vs default).

### Endpoints

Global routes (outside any `DomainConstraint`), alongside the Phase A + 02a routes.

| Verb | Path | Controller#Action | Purpose | Auth |
|------|------|-------------------|---------|------|
| POST   | `/my/lists`            | `my_lists#create`  | Create a custom list (HTML form); redirects to its edit page | signed-in |
| GET    | `/my/lists/:id/edit`   | `my_lists#edit`    | Drag-and-drop edit page | owner |
| PATCH  | `/my/lists/:id`        | `my_lists#update`  | Batch save: metadata + reorder + remove (transactional); redirects to show | owner |
| DELETE | `/my/lists/:id`        | `my_lists#destroy` | Delete a **custom** list; redirects to dashboard | owner |
| PATCH  | `/user_lists/:user_list_id/items/:id` | `user_list_items#update` | Set/clear `completed_on` (JSON) | owner |

Route helpers: `edit_my_list_path(list)`; `my_list_path(list)` for PATCH/DELETE. The item PATCH reuses the 02a `user_list_item` path namespace.

**CSRF**: standard `<meta name="csrf-token">`. **Caching**: every action calls `prevent_caching`.

### Schemas (JSON — `completed_on` editor only)

**Request — `PATCH /user_lists/:user_list_id/items/:id`**
```json
{
  "type": "object",
  "required": ["user_list_item"],
  "properties": {
    "user_list_item": {
      "type": "object",
      "properties": {
        "completed_on": { "type": ["string", "null"], "format": "date",
          "description": "ISO 8601 (YYYY-MM-DD); null clears it" }
      },
      "additionalProperties": false
    }
  }
}
```

**Response — 200** (extends `UserListItemSummary` from 02a with `completed_on`)
```json
{ "user_list_item": { "id": 555, "user_list_id": 99, "listable_type": "Music::Album",
                      "listable_id": 9876, "position": 3, "completed_on": "2026-03-15" } }
```
Errors use the shared 02a contract (`JsonErrorResponses`): `unauthenticated` (401), `forbidden` (403), `not_found` (404), `validation_failed` (422).

**`completed_on` validation.** Column is nullable (`null` clears it). A syntactically invalid date string must return **422**, not 500 — Rails' `Date.parse`/multiparameter path can raise `Date::Error`/`ArgumentError`, so the controller must guard (rescue → `render_validation_failed`, or validate before assignment). Future dates permitted.

### HTML form params

**`POST /my/lists`** (create custom list from the dashboard)
- `user_list[name]` (required), `user_list[description]`, `user_list[public]`
- `user_list[type]` — chosen STI subclass name; **must be one of `UserList.subclasses_for(Current.domain)`**. Required when the domain has >1 subclass (music); single-subclass domains default it. `list_type` forced to `:custom` server-side.

**`PATCH /my/lists/:id`** (batch edit save)
- `user_list[name]`, `user_list[description]`, `user_list[public]`, `user_list[view_mode]`
- `ordered_listable_ids` — comma-joined `listable_id`s in final order (after removals; **no** trailing comma)
- `removed_listable_ids` — comma-joined `listable_id`s to delete

Controller parses both with `.to_s.split(",").reject(&:blank?).map(&:to_i)` and applies in one transaction: (1) update metadata, (2) destroy removed items, (3) `reorder_items!(ordered_listable_ids)` on survivors (skip if empty). `reorder_items!` validates the ordered set exactly matches the survivors. Note: `UserListItem#shift_positions_up` is `after_destroy_commit` (fires after the outer transaction commits) — by then `reorder_items!` has written contiguous `1..N`, so the compaction is a no-op (`WHERE position <> new_position` matches nothing). No hazard.

### Authorization (Pundit)

**`UserListPolicy`** (extend Phase A):

| Action | Rule |
|---|---|
| `update?`  | `owner?` |
| `destroy?` | `owner? && !record.default?` (custom lists only) |

**`UserListItemPolicy`** (extend 02a):

| Action | Rule |
|---|---|
| `update?` | `record.user_list.user_id == user&.id` |

Pass `policy_class:` explicitly. Controllers load via `current_user.user_lists.find(...)` so non-owners 404 before the policy runs. A forced `destroy?` on a default list is denied by Pundit → `user_not_authorized` **redirects with a flash alert** (HTML; not a 403 status).

### Controllers

**`MyListsController` (extend Phase A)** — add `create`, `edit`, `update`, `destroy`.
- `create`: build `current_user.user_lists.new`, resolve `type` from `UserList.subclasses_for(Current.domain)`, force `list_type: :custom`, `authorize ..., :create?, policy_class: UserListPolicy`, save, redirect to `edit_my_list_path`. **Error path:** on `RecordInvalid` (blank name) re-render `index` with the form open + errors (or redirect back with a flash alert). On a multi-subclass domain (music), a missing/invalid `type` is a validation error.
- `edit`: load via `current_user.user_lists.find` (404 non-owner); load **all** items (unpaginated) ordered + eager-loaded for the drag UI.
- `update`: `authorize @list, :update?, policy_class: UserListPolicy`; parse `ordered_listable_ids`/`removed_listable_ids`; run the transactional batch above; redirect to `my_list_path` with a flash notice; on `RecordInvalid`/`ArgumentError`, re-render `:edit` with a flash alert.
- `destroy`: `authorize @list, :destroy?, policy_class: UserListPolicy`; destroy; redirect to `my_lists_path`.

**`UserListItemsController` (extend 02a)** — add `update` (JSON). Loads `current_user.user_lists.find(params[:user_list_id])` then the item; `authorize item, :update?, policy_class: UserListItemPolicy`; permits only `completed_on`; renders the item summary. Keep `prevent_caching` + `JsonErrorResponses` (must rescue the invalid-date case → 422).

### ViewComponents

- **`UserLists::Edit::ItemRowComponent`** (new) — one draggable row on the edit page: position badge, drag handle (`data-sortable-handle`), title/subtitle, "Move to top/bottom" menu, remove button; carries `data-listable-id`. Args: `item:`, `index:`.
- **`UserLists::Show::ItemComponent`** (extend Phase A) — add the inline `completed_on` editor (an `<input type="date">` wired to `user-list-item-date`) in `default_view` and `table_view` when `completed_on_enabled?`. `grid_view` keeps the read-only badge from Phase A.

### Stimulus Controllers (JavaScript)

Add the dependency: `yarn add sortablejs` (Rollup's existing `node-resolve` + `commonjs` plugins handle it; no config change), then `yarn build`. Register new controllers via `bin/rails stimulus:manifest:update`.

**`user_list_sort_controller.js` (new)** — the edit page (mirrors the old app's controller, DaisyUI-styled):
```javascript
// reference only — public surface
static targets = ["form", "list", "saveButton", "removedIds"]
connect()          // Sortable.create(listTarget, {animation:150, handle:"[data-sortable-handle]",
                   //   ghostClass:"opacity-50", onEnd:updateOrder}); snapshot originalOrder;
                   //   track removed Set; beforeunload guard for unsaved changes
updateOrder()      // diff vs originalOrder; enable/disable save; renumber position badges live
removeRow(e)       // add listable-id to removed Set; remove row; refresh removedIds; updateOrder
moveTop(e) / moveBottom(e)
save(e)            // intercept submit; append ordered_listable_ids + removed_listable_ids (comma-joined,
                   //   NO trailing comma); fetch PATCH with FormData body (form-encoded, NOT JSON — so Rails
                   //   renders a normal 302 the controller handles as HTML) + X-CSRF-Token from meta tag;
                   //   on ok → Turbo.visit(response.url)
```
Turbo is in the stack (`@hotwired/turbo-rails`); `Turbo.visit` gives a smooth transition (`window.location` also works).

**`user_list_item_date_controller.js` (new)** — inline `completed_on` editor on the show page. Snapshots the field's previous value on focus; on `change`, `PATCH`es `/user_lists/:lid/items/:id` (JSON, meta CSRF), then dispatches `toast:show`. On error (422/network) it **reverts the input to the snapshot** and shows an error toast. No localStorage interaction.

### View / Layout changes
- **`web-app/app/views/my_lists/edit.html.erb`** (new) — metadata form + the SortableJS list of `Edit::ItemRowComponent` rows + Save/Cancel; warns on unsaved changes. The edit page **always displays items in `position` order**, regardless of the show page's last sort.
- **`web-app/app/views/my_lists/index.html.erb`** (extend Phase A) — add a DaisyUI create-list modal/form posting to `POST /my/lists`; include a `type` selector ("Album list" / "Song list") when the domain has >1 subclass.
- **`web-app/app/views/my_lists/show.html.erb`** (extend Phase A toolbar) — add Edit and (custom only) Delete buttons; the Add-item slot stays a placeholder until `02e`.

### Behaviors (pre/postconditions)

**Create custom list**
- Pre: owner submits the dashboard create form.
- Post: a `:custom` list of the chosen domain-valid subclass is created; redirect to its edit page. Edge: blank name → re-render dashboard with the form open + error; missing `type` on music → validation error.

**Edit: reorder + remove + metadata (batch)**
- Pre: owner opens `/my/lists/:id/edit`, drags rows, removes some, edits name, clicks Save.
- Post: one `PATCH` updates metadata, destroys removed items (positions re-compact via `shift_positions_up`), and `reorder_items!` applies the final order to survivors; redirect to show. The edit page always shows position order; saving operates on position. Edge: blank name → re-render edit with error, nothing persisted (transaction rolls back); `ordered_listable_ids` not matching survivors → `ArgumentError` → re-render edit with alert; removing all items → reorder skipped.
- Note: the edit page is **unpaginated** (drag needs the full set in the DOM). Lists are personal and typically small; "Move to top/bottom" remains a non-drag fallback for large lists. Cross-page drag is out of scope.

**Edit `completed_on` (inline, show page)**
- Pre: owner on a completion-type list (`completed_on_enabled?`) changes/clears an item's date (default or table view).
- Post: `PATCH .../items/:id` persists; toast confirms. Non-completion lists never render the editor. 422 (e.g. invalid date) → error toast, field reverts to its previous value. Grid view shows the date read-only (switch views to edit).

**Delete custom list**
- Pre: owner clicks Delete on a **custom** list (confirm dialog).
- Post: list + items destroyed; redirect to dashboard with a notice. Default lists never show Delete; a forced `destroy?` redirects with an alert.

### Non-Functionals
- **Auth/roles**: all actions require sign-in; owner-only via `current_user.user_lists` scoping (404 for others); `destroy?` blocks default lists.
- **Caching**: every action sets `Cache-Control: no-store, ... private`.
- **CSRF**: standard meta-token flow (uncached pages).
- **Performance**: edit eager-loads `:listable` + display associations (verify no N+1 on a 100-item list); batch save is one transaction.
- **UX**: edit warns on unsaved changes (`beforeunload`); Save disabled until a change; live position renumbering on drag; SortableJS uses a drag **handle** so touch scroll still works.

## Acceptance Criteria
- [ ] `POST /my/lists` creates a `:custom` list of the chosen (domain-valid) subclass; rejects a `type` outside `UserList.subclasses_for(Current.domain)`; redirects to its edit page; blank name re-renders the dashboard with errors.
- [ ] `GET /my/lists/:id/edit` (owner) renders draggable rows with handles, remove buttons, and a metadata form; non-owner → 404; items shown in `position` order.
- [ ] `PATCH /my/lists/:id` applies metadata + removals + `reorder_items!` atomically; a blank name rolls back the whole transaction and re-renders edit; a mismatched `ordered_listable_ids` re-renders edit with an alert.
- [ ] After removing items + reordering in one save, surviving items have contiguous `position` 1..N in the saved order.
- [ ] `DELETE /my/lists/:id` deletes a custom list; default lists have no Delete control; a forced `destroy?` on a default list is denied by Pundit → redirect with a flash alert (not a 403 status); the custom-vs-default rule is unit-tested at the policy level.
- [ ] `PATCH /user_lists/:user_list_id/items/:id` sets/clears `completed_on` (JSON) for owner; 404 for non-owner; a syntactically invalid date returns 422 (not 500); the editor renders only for `completed_on_enabled?` lists (default + table views; read-only badge in grid).
- [ ] Pundit: `UserListPolicy#update?`/`#destroy?` and `UserListItemPolicy#update?` enforce owner-only (covered by policy tests); `destroy?` blocks default lists.
- [ ] SortableJS added to `package.json`; `user-list-sort` + `user-list-item-date` registered in `controllers/index.js`; the bundle builds.
- [ ] `user-list-sort#save` submits FormData (form-encoded, not JSON) and the controller handles the redirect; the inline date editor reverts on error.
- [ ] All Phase B responses carry `Cache-Control: no-store, ... private`.
- [ ] Existing suite green; new controller, policy, and model/JS-adjacent tests cover every server-side criterion above.

### Golden Examples

**Example 1 — batch edit save**
```
1. Owner opens /my/lists/99/edit (custom album list, 5 items)
2. Drags item C above item A, removes item E, renames to "90s Essentials", Saves
3. user-list-sort#save → PATCH /my/lists/99 (FormData) with
   user_list[name]="90s Essentials", ordered_listable_ids="C,B,A,D", removed_listable_ids="E"
4. One outer transaction: update name → destroy E → reorder_items!(["C","B","A","D"]).
   shift_positions_up is after_destroy_commit, fires post-commit as a no-op (positions
   already 1..N). Redirect to /my/lists/99; positions C=1,B=2,A=3,D=4.
```

**Example 2 — inline completed_on**
```
1. Owner on /my/lists/43 ("Albums I've Listened To"; list_type=:listened,
   completed_on_enabled? == true), table view
2. Sets an item's date input to 2026-03-15
3. user-list-item-date → PATCH /user_lists/43/items/555 {"user_list_item":{"completed_on":"2026-03-15"}}
4. 200 → toast "Saved". A bad value → 422 → error toast, field reverts.
   On a :favorites list the date editor never renders.
```

**Example 3 — create + delete**
```
1. Owner on the music dashboard opens "Create a new list", picks type "Album list",
   name "My Top 50 of the 90s", Saves → POST /my/lists → redirect to its /edit page.
2. Later clicks Delete on that custom list → confirm → DELETE /my/lists/:id →
   redirect to /my/lists. A default list ("Favorite Albums") shows no Delete control.
```

---

## Agent Hand-Off

### Constraints
- Build on Phase A (`02`) — do not duplicate its dashboard/show/components/routes; extend them.
- One new JS library only: **SortableJS** (`yarn add sortablejs`). No new gems.
- Do not add an "add item to this list" affordance — that's `02e`.
- `show?` stays owner-only (public viewing is `02d`).
- No schema migration; snippet budget ≤40 lines.

### Required Outputs
- New/modified files in "Key Files Touched".
- Minitest coverage for every server-side acceptance bullet (controllers, policies, transaction rollback, `completed_on` 422, custom-vs-default delete).
- Manual visual verification of the drag-and-drop edit save, create, delete, and inline `completed_on` on music (albums) and games dev subdomains.
- Updated `docs/features/user-lists.md` with the management/editing surface.
- Filled-in "Implementation Notes" and "Deviations" below.

### Sub-Agent Plan
1. `codebase-pattern-finder` → confirm the existing edit/ViewComponent/Stimulus patterns + the old-app SortableJS controller to mirror.
2. `codebase-analyzer` → re-verify `reorder_items!` + `shift_positions_up` timing and the `completed_on` validation path before wiring `update`.
3. `web-search-researcher` → SortableJS API specifics if needed.
4. `technical-writer` → update `docs/features/user-lists.md` + class docs.

### Test Seed / Fixtures
- Reuse `web-app/test/fixtures/user_lists.yml` + `user_list_items.yml`. Add minimal fixtures only if a reorder/remove/transaction case needs them.

---

## Implementation Notes (living)
- Approach taken:
- Important decisions:

### Key Files Touched (paths only)
- `web-app/config/routes.rb`
- `web-app/app/controllers/my_lists_controller.rb` (add `create`, `edit`, `update`, `destroy`)
- `web-app/app/controllers/user_list_items_controller.rb` (add `update`)
- `web-app/app/policies/user_list_policy.rb` (`update?`, `destroy?`), `web-app/app/policies/user_list_item_policy.rb` (`update?`)
- `web-app/app/components/user_lists/edit/item_row_component.{rb,html.erb}` (new)
- `web-app/app/components/user_lists/show/item_component.{rb,html.erb}` (add inline date editor)
- `web-app/app/views/my_lists/edit.html.erb` (new); `index.html.erb` (create form); `show.html.erb` (Edit/Delete toolbar)
- `web-app/app/javascript/controllers/user_list_sort_controller.js` (new)
- `web-app/app/javascript/controllers/user_list_item_date_controller.js` (new)
- `web-app/app/javascript/controllers/index.js` (regenerated)
- `web-app/package.json` + lockfile (`sortablejs`)
- Tests under `web-app/test/{controllers,policies,models}/`

### Challenges & Resolutions
- …

### Deviations From Plan
- …

## Acceptance Results
- Date, verifier, artifacts (screenshots/links):

## Future Improvements
- Add-item-from-list-page (`02e`); public discovery / badges (`02d`); list-level reordering; bulk multi-select remove on the edit page.

## Related PRs
- _to be filled when the PR is opened_

## Documentation Updated
- [ ] `docs/features/user-lists.md` — management/editing surface
- [ ] Class docs for new controller actions, components, Stimulus controllers
- [ ] This spec — Implementation Notes, Deviations, Acceptance Results
