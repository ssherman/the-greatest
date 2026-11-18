# Edit Page Design Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the Edit list page to layout B. Make the ⋯ menu a real daisyUI 5 menu. Move
"Move to position…" into a dialog. Restore the pointer cursor on buttons site-wide. Keep keyboard
focus on the acted-on row.

**Architecture:**
- View and component changes only. The endpoints, services and Turbo Stream morph behaviour from
  PR #514 are unchanged.
- The menu's actions keep posting through hidden forms, which each `<button form="…">` targets.
  daisyUI then styles the buttons as menu items.
- A new position dialog is rendered once per page, the same way the completion dialog is.

**Tech Stack:** Rails 8, ViewComponent, Stimulus, Turbo 8, daisyUI 5 / Tailwind 4, lucide
icons (`helpers.icon name, library: "lucide"`), Minitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-17-user-lists-management-design.md`. The binding part
is the "Addendum (2026-11-18): Edit page design pass" at the end. The earlier sections still
apply: no navigation or scroll jump, a Turbo Stream on every write answer, and every view
rendering for books, albums, songs and games.

## Global Constraints

- Branch `worktree-user-lists-management`, in the worktree at
  `/home/shane/dev/the-greatest/.claude/worktrees/user-lists-management`. Rails and yarn
  commands run from `web-app/`. Never push.
- **daisyUI 5 only.** Never use `form-control`, `label-text`, `input-bordered` and the like
  (AGENTS.md lists the ten removed classes). The authority is the root-level
  `docs/external-libraries/daisyui-llms.txt`.
- **Menu contract.** Inside `ul.menu`, each `<li>`'s direct child is the interactive element: a
  `<button>`, or a non-interactive divider. No `<form>` sits between them.
- **Exact copy:**
  - Built-in badge: "Built-in"
  - Locked hint: "Built-in lists keep their names."
  - Public toggle label: "Public"
  - Menu items: "Move to top", "Move to bottom", "Move to position…",
    "Set <completion_label.downcase> date…"
  - Dialog title: `Move “<title>”`
  - Dialog subtitle: `Currently #<position>`
  - Dialog input label: `New position (1–<count>)`
  - Dialog buttons: "Cancel", "Move"
- **The count line uses the list's noun.** It reads "<n> books" / "1 book" (albums, songs and
  games likewise). Use `UserList#listable_noun` (plural) for n ≠ 1 and the singular
  `listable_class.model_name.human.downcase` for 1.
- `yarn build:all` after any JS or CSS change. Stimulus controllers are registered by hand in
  `app/javascript/manifests/web_shared.js`; that file says not to run the manifest task.
- **Before done:** `bin/rails test` (foreground; `Oauth::FlowTest` "31st token request" is a
  known flake when a run crosses a minute boundary), `bundle exec standardrb`,
  `CI=1 bin/rails zeitwerk:check`.
- **E2E only on this worktree's server.** Run Playwright only after the AGENTS.md port-3000 check
  shows the port is free or owned by this worktree. Never kill another server.

## Review Focus

1. **Move to position with a bad value** (blank, 0, more than the count, "abc"). The browser's
   `required`/`min`/`max` checks block submission. A crafted request still gets the server's 422
   toast, and nothing moves. Task 13 adds the component attributes test; the server test already
   exists.
2. **Move to position from page 2.** The dialog posts the current `page`, so the morph re-renders
   page 2, not page 1. Task 13 adds a controller-level test through the dialog form's params.
3. **Escape or Cancel on the position dialog.** Nothing is submitted, and focus returns to the
   row that opened it. Task 14 E2E covers this.
4. **A list with one item.** The dialog shows "New position (1–1)", and Move to top and Move to
   bottom are no-ops with no error toast. Task 13 adds a component test.
5. **A song list (no covers, tabular elsewhere) on the Edit page.** It renders with the new menu
   and dialog. Task 13 adds a component test with `regular_user_music_songs_favorites`.

---

### Task 12: Layout B (header, details card, count line, softer rows)

**Files:**
- Modify: `app/views/my_lists/edit.html.erb`
- Modify: `app/components/user_lists/edit/details_form_component.html.erb` (+ `.rb` if helpers are
  needed)
- Modify: `app/components/user_lists/edit/rows_component.html.erb`
- Modify: `app/components/user_lists/edit/row_component.html.erb` (badge and by-line only; the
  menu is Task 13's)
- Test: `test/components/user_lists/edit/*_test.rb`, `test/controllers/my_lists_controller_test.rb`,
  `test/controllers/my_list_items_controller_test.rb` (the count assertions change wording)

**Interfaces:**
- Produces:
  - The details card keeps `id="list-details"` and `#list-details-errors`. The `update` stream
    replaces `list-details`, so the whole card must render from `DetailsFormComponent`.
  - The Delete button is inside the card but submits a separate hidden form,
    `<form id="delete-list-form" …>`, rendered in `edit.html.erb` outside the details form. The
    button carries `form="delete-list-form"` and the existing `turbo_confirm` copy.
  - `#edit-list-rows` keeps its id and `[overflow-anchor:none]`. The count element keeps
    `data-testid="item-count"`, and the rows target container is unchanged.

- [ ] **Step 1: Failing tests.**
  - DetailsFormComponent:
    - "renders a toggle, not a checkbox, for public": `assert_selector "input[type=checkbox].toggle"`.
    - "custom list shows Delete list wired to delete-list-form":
      `assert_selector "button[form=delete-list-form]", text: "Delete list"`.
    - "default list shows no Delete list".
  - RowsComponent: "count uses the list noun". For a books list with 2 items, "2 books"; with 1,
    "1 book".
  - RowComponent: "date sits on the by-line". The by-line paragraph contains both the author and
    "Finished".
  - Edit view (controller test): `assert_select "h1", text: /Books I've Read/` (use the fixture's
    real name) and a "Built-in" badge on default lists only.
  - Update the existing "N items" assertions to the noun form.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement.**
  - **Page wrapper:** `container mx-auto max-w-3xl px-4 py-8`.
  - **Header:** h1 = `@list.name`, plus `badge badge-ghost` "Built-in" with a lucide `lock` icon
    when default.
  - **Card:** `card bg-base-100 shadow-sm` with `card-body`.
    - Row 1: name `fieldset` (`flex-1`), then a `label` holding the `toggle` and "Public".
    - Then the description `textarea`, `rows: 3`.
    - Footer `card-actions justify-between`: Delete on the left (`btn btn-ghost text-error`,
      custom lists only, an empty `<span>` otherwise), Save (`btn btn-primary`) on the right.
  - **Count line:** a flex row, `justify-between items-center`, with the count text on the left
    and the top pager on the right. Keep the bottom pager.
  - **Badge:** `badge badge-ghost` (not neutral).
  - **By-line:** author, then ` · `, then the `CompletionDateComponent :row` output.
  - **Date stream (my call):** `CompletionDateComponent :row` must render inline (a `span`, not a
    `p`), so it can sit on the by-line. Its root id must stay `dom_id(item, :completion)` so the
    date stream still replaces it. Update that component's tests.

- [ ] **Step 4: Run** `bin/rails test test/components/user_lists test/controllers/my_lists_controller_test.rb test/controllers/my_list_items_controller_test.rb test/controllers/user_list_items_controller_test.rb`. **Expect PASS.**

- [ ] **Step 5: Commit** "Edit page: layout B header, details card and count line".

### Task 13: Real ⋯ menu, Move to position dialog, focus

**Files:**
- Modify: `app/components/user_lists/edit/row_component.html.erb` (+ `.rb`)
- Create (generator): `UserLists::Edit::PositionDialogComponent` (`user_list:`, `page:`)
- Create: `app/javascript/controllers/user_list_position_controller.js`, registered in
  `manifests/web_shared.js`
- Modify: `app/views/my_lists/edit.html.erb` (render the dialog once; add the controller to the
  wrapper)
- Modify: `app/javascript/controllers/user_list_edit_controller.js` (focus the row instead of
  blurring)
- Modify: `app/javascript/controllers/user_list_completion_controller.js` (focus after the
  stream renders)
- Test: component tests for RowComponent and PositionDialogComponent;
  `test/controllers/my_list_items_controller_test.rb`

**Interfaces:**
- Consumes: the existing `PATCH move_my_list_item_path(list, item)` with
  `user_list_item[position]` and `page`, which answers with the morph stream.
- Produces:
  - **Row menu.** For each row, the hidden forms come first, all outside the `ul`:
    - `form#<dom_id(item, :move_top)>`, posting position 1
    - `form#<dom_id(item, :move_bottom)>`, posting position `item_count`

    Then `ul.menu.dropdown-content` holds:
    - `li > button[form=…]` "Move to top", with lucide `arrow-up-to-line`
    - `li > button[form=…]` "Move to bottom", with lucide `arrow-down-to-line`
    - `li > button[data-action="user-list-position#open"]` "Move to position…", with lucide
      `hash`. It carries `data-item-id`, `data-item-title`, `data-position` and
      `data-max=item_count`.
    - a divider `li`
    - the existing "Set … date…" button, with lucide `calendar`
  - **Position dialog.** It is a `<dialog id="position-dialog" class="modal">` with targets
    dialog, form, title, current, label and input.
    - The form posts PATCH to the move URL built from a `data-user-list-position-url-value`
      template containing `__ID__`.
    - It carries a hidden `page` field and
      `input[type=number][name="user_list_item[position]"][min=1][required]`, whose `max` is set
      when the dialog opens.
    - Cancel calls `dialog.close()`.
    - On `turbo:submit-end`, if `success`, the dialog closes.
  - **Focus algorithm.** This is the one non-obvious part:

```javascript
// user_list_edit_controller.js, on turbo:submit-start inside a row menu:
//   const row = event.target.closest("[data-item-id][tabindex='-1']") ?? the opener's row
//   this.pendingFocusId = row?.dataset.itemId
// on turbo:before-stream-render (document): wrap the render so that after it runs,
//   requestAnimationFrame(() => document.querySelector(`[data-item-id="${id}"][tabindex='-1']`)?.focus({preventScroll: true})
//   ?? document.querySelector("#edit-list-rows [data-testid=item-count]")?.focus  // row left the page
// The completion controller uses the same wrap to re-find its replaced opener on the list page.
```

  The fallback heading needs `tabindex="-1"` when it is the target. Use `preventScroll: true` so
  focus never scrolls the page.

- [ ] **Step 1: Failing tests.**
  - **RowComponent:**
    - "menu items are direct li > button children": `assert_selector "ul.menu > li > button", text: "Move to top"`, and the same for "Move to bottom" and "Move to position…".
    - "Move to top targets its hidden form": `assert_selector "button[form='#{dom_id(item, :move_top)}']"` and `assert_selector "form##{dom_id(item, :move_top)} input[name='user_list_item[position]'][value='1']", visible: :all`.
    - "no form element inside the menu": `refute_selector "ul.menu form"`.
    - "renders for a songs list" (Review Focus 5).
    - "one-item list: bottom form posts 1" (Review Focus 4).
  - **PositionDialogComponent:**
    - "has a required number input with min 1 and a page field".
    - "Cancel and Move buttons".
  - **Controller (my_list_items):** "a move posted with page 2 re-renders page 2" (Review Focus
    2). Stub the page limit to 2, as the existing clamped-page test does.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement.** Delete the old inline position `form_with` from the menu.

- [ ] **Step 4: Run** the focused tests; then `yarn build:all`. **Expect PASS.**

- [ ] **Step 5: Commit** "Edit page: real daisyUI menu, Move to position dialog, keep focus on the row".

### Task 14: Pointer cursor, E2E, docs, verification

**Files:**
- Modify: `app/assets/stylesheets/{books,music,games}/application.css`. Add, in `@layer base`:
  `button:not(:disabled), [role="button"]:not(:disabled) { cursor: pointer; }`
- Modify: `e2e/tests/books/account/edit-list.spec.ts`; the root-level `docs/features/user-lists.md`
  (Edit page section)

- [ ] **Step 1: E2E changes in `edit-list.spec.ts`.**
  - **Move to position:** the test now goes ⋯ → "Move to position…" → dialog. It fills
    `getByLabel(/New position/)`, clicks "Move", and asserts the dialog closes. Scroll and URL
    stay unchanged, and the order changes.
  - **Pointer cursor:** a new assertion that the menu buttons show a pointer:
    `expect(await button.evaluate(el => getComputedStyle(el).cursor)).toBe('pointer')` on "Move to
    top".
  - **Dialog dismissal (Review Focus 3):** "Escape closes the position dialog without moving, and
    focus returns to the row". Check `document.activeElement` is the row with that item's
    `data-item-id`.
  - **Focus after a menu move:** after "Move to top", `document.activeElement` is the moved row,
    with no `<body>` focus.
  - **Built-in lists:** the existing test still asserts no "Delete list".

- [ ] **Step 2: Run.**
  1. `yarn build:all`.
  2. Check port 3000.
  3. Start `bin/rails server` in the background.
  4. Run `bin/rails e2e:prepare`.
  5. Run `yarn test:e2e e2e/tests/books/account/edit-list.spec.ts e2e/tests/books/account/my-lists.spec.ts e2e/tests/books/account/reading-goals.spec.ts` twice. **Expect all green both times.**
  6. Stop the server.

- [ ] **Step 3: Update `docs/features/user-lists.md`'s Edit page section.**
  - The layout.
  - The menu, and why the forms are hidden (the daisyUI `li > *` contract).
  - The position dialog.
  - The focus behaviour.
  - The site-wide pointer rule.

- [ ] **Step 4: Verify.** Run `bin/rails test`, `bundle exec standardrb` and
  `CI=1 bin/rails zeitwerk:check`.

- [ ] **Step 5: Commit** "Pointer cursor on buttons; Edit page E2E and docs for the design pass".
