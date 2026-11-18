# User Lists Management (web Phase B) — Design

**Date:** 2026-11-17
**Status:** Draft, awaiting approval
**Replaces:** the archived `docs/specs/user-lists-02f-list-management-and-editing.md` (never built). Its
"separate edit page, batch save" model is dropped. See Approaches.

## Why

Signed-in members cannot manage their lists on the web. Today the only write surface is the "Add to
list" modal, which can create a custom list and tick lists on and off. Members cannot rename or
delete a list, reorder its items, or remove an item from the list page. The library API (#510,
merged 2026-11-16) can do all of this, so the web is now behind the API. Books is close to launch,
and these pages are its members' library.

There are two more reasons:

- **Favorites feed the rankings.** Each domain's users' favorites ranking scores a Favorites list
  by position once it is `manually_ordered`, and by even shares until then
  (`Services::Lists::UserFavoritesTally`). Without a reorder UI, `manually_ordered` can never become
  true for a new member. Positional scoring then only serves the 257 legacy books lists that had it.
  Members are also never told that Favorites counts toward the rankings.
- **The list page looks bad.** Every item on a *Read* list carries a visible button reading "Edit
  completion date for &lt;title&gt;", in all three view modes. The List view mode is a relic of the old
  app: 2 of 291,000 lists use it.

These pages are global routes shared by books, music and games (`MyListsController`,
`Current.domain`), so everything here ships to all three. Movies stays out of scope.

## Goals

1. Create a custom list from the My Lists dashboard.
2. Edit a list on a separate **Edit list** page, modelled on Shane's old site (which copied
   Letterboxd). The page has:
   - a details form: name, description, public
   - numbered rows, reorderable by drag
   - a ⋯ menu on each row with Move to top, Move to bottom, Move to position…, and (on the Read list
     only) Set finish date…
   - remove (✕) with Undo
   - Delete list (custom lists only)
3. Built-in lists **cannot be renamed or deleted**: every non-`custom` list type, i.e. books'
   Favorites, Read, Currently reading and Want to read, and their music and games equivalents. Their
   description and public setting can still change. This matches the API.
4. Tell members that Favorites counts toward the site rankings, on the dashboard card, the list page
   and the edit page. The wording comes from Shane's approved mockup: "Your Favorites count toward
   the site rankings. Put them in order and the books near the top count for more." Each domain
   swaps in its own noun (books, albums, songs, games).
5. Remove the List view mode. Grid and Table remain.
6. Replace the per-item "Edit completion date for …" buttons. This applies to **every list with
   completion dates** (`completed_on_enabled?`), not only books' Read: music's Listened, and games'
   Played and Beaten, behave the same way. The date's label follows the list type: Read →
   "Finished", Listened → "Listened", Played → "Played", Beaten → "Beaten" (**my call**). The
   examples below use books:
   - **Grid:** the date shows as quiet text under the cover ("Finished Mar 3, 2026"). There is no
     control.
   - **Table:** the Finished cell holds the date as a clickable link-styled value, or a faint
     "Add date" when the item has none. It opens the existing completion dialog.
   - **Edit page:** "Set finish date…" in the row's ⋯ menu opens the same dialog.
7. Add a **Recently added** sort to the list page, next to Position (relabelled **Your order**) and
   Ranking. A just-finished book is otherwise at the bottom of a long Read list, where it is hard to
   reach. Reading goals only count books that have a finish date, so setting one must stay easy.

## Non-goals

- Reordering the lists themselves on the dashboard. `user_lists.position` exists but is unused (0
  rows set) and stays unused. Built-in lists come first, then custom lists by name, as today.
- Public discovery of other members' lists, and "consumed" badges (`user-lists-02d`).
- Asking for a finish date when a book is ticked onto Read in the Add-to-list modal. This is a
  possible follow-up, not this work.
- Changing the API's behaviour. API code moves into shared services, and its tests must still pass
  unchanged.
- The API's custom-list cap (`config.x.api.max_custom_lists`). It applies to API creation only, as
  #510 decided, and the web's create stays uncapped. **My call:** the cap does not extend to the
  web.
- Movies.

## Anti-goals

These would make the work a failure even if it technically worked:

- **The page jumps or flickers when you move a book.** No full-page reload, no frame reload that
  repaints the list, and no scroll to the top after a move, remove, undo or date change (Shane's
  explicit requirement).
- **The web and the API disagree.** If a rule is enforced in one place and not the other (renaming a
  built-in list, the `manually_ordered` flag, the Read → Reading transition, reading-goal
  invalidation), that is a bug.
- **Numbers on the edit page that differ from the stored positions.** The page shows each item's
  stored `position`, never a client-side count.
- **An edit page that falls over on a big list.** The median list has 10 items, the 99th percentile
  430, and the largest 24,563 (dev database, 2026-11-17).

## Approaches considered

### Saving order: batch Save vs. save each move

- **Batch save (old site, old 02f spec).** Load every item, drag freely, and one Save posts the
  whole order. Shane liked this on the old site. It cannot handle the largest lists: 24k rows in the
  DOM and a 24k-id POST, and reordering across pages is impossible once the list is paginated. A
  hybrid (full load under 1,000 items, paginated with instant saves above) means two behaviours to
  build and explain.
- **Save each move (chosen by Shane).** The edit page shows 100 items per page, like the list page.
  Every move, remove and date change saves as it happens. There is no Save/Cancel for the order,
  while the details form keeps its own Save. It behaves the same at 10 items and at 24,000, and it
  uses `Services::UserLists::MoveItem`, which shifts positions in a single UPDATE. The cost is that
  there is no Cancel to throw away a series of drags. Undo on remove covers the destructive case.

### Updating the screen after a move: server re-render vs. client-owned order

- **Server re-render (chosen by Shane).** The row moves in the DOM right away (Sortable's drop,
  or the menu action). The request returns a Turbo Stream that **morphs** the page's rows container
  (`turbo_stream.replace … method: :morph`), so only the changed numbers update. The scroll position
  stays put and nothing repaints. The server is the only source of numbering, which handles hidden
  provisional items. The app already uses Turbo 8 morphing (`turbo_refreshes_with method: :morph,
  scroll: :preserve` on the admin duplicate-candidates queue).
- **Client-owned order.** The browser renumbers and sends JSON, and reverts on error. It is slightly
  snappier, but it would need the hidden-item numbering in JavaScript and adds a second write
  pattern. Rejected.

### Drag library: SortableJS (chosen by Shane)

npm data checked 2026-11-17:

- **SortableJS** (5.8M weekly downloads, 1.15.7 Feb 2026, MIT). Other rows slide out of the way
  while you drag, which is the feel of the old site and Letterboxd. Touch works out of the box, and
  it scrolls the page when you drag near the edge. It doesn't depend on any framework. Releases are
  slow, which is acceptable because the ⋯ menu covers every move without dragging.
- **Pragmatic drag and drop** (Atlassian; 3.0M, 4.0.0 Sep 2026). Actively maintained, but
  low-level: it draws a drop line rather than shifting rows. Indicators and auto-scroll are ours to
  build, and its ready-made pieces are React-only. Rejected: more code for a feel further from what
  Shane wants.
- **Shopify Draggable** (122k): small user base. **dragula**: abandoned since 2022. **Native HTML5
  drag and drop**: poor touch behaviour, and we would rebuild what SortableJS gives.
- **@stimulus-components/sortable**: a wrapper around SortableJS whose save-on-drop request does not
  fit our neighbour-position calculation and morphing Turbo Stream reply. Instead, our own small
  Stimulus controller uses SortableJS directly.

## Design

### Increments (my call, proposed to Shane and not objected to)

Two PRs. The first is useful alone, and the drag work gets its own review.

- **Increment 1: dashboard and list page.** Shared list services, the dashboard **New list** dialog,
  List view removal, the finish-date display and table "Add date", the Recently added sort, and the
  Favorites note on the dashboard and list page.
- **Increment 2: Edit list page.** Details form, delete, reorder (drag + ⋯ menu), remove with Undo,
  Set finish date…, and the Favorites note on the edit page.

### Shared services

Create, rename and delete live inside `Api::V1::Books::My::ListsController` today. They move into
`app/lib/services/user_lists/` (names are the builder's) with the Result pattern, and both the API
and the web call them:

- **Create custom list:** forces `list_type: :custom` and validates the name: stripped, 1–100
  characters, no NUL. Description is up to 1,000 characters, blank stored as null. The class comes
  from `UserList.subclasses_for(Current.domain)`. Music has two subclasses, so its dialog picks
  Albums or Songs, as the modal's create path already does.
- **Update list:** name, description, public. Refuses a name change on a default list.
- **Delete list:** refuses a default list. Otherwise it runs under `OwnerMutation` and deletes the
  items with one `delete_all` then destroys the list, as the API does. The API's comment explains why
  no reading-goal purge is needed.

The API controller keeps its JSON parsing, 400s, the cap and the budget, and calls the services for
the rules. Its existing tests are the check that its behaviour has not changed. Item writes on the
edit page use the services that already exist: `UpdateItem` (position and/or completion, under
`OwnerMutation`), `RemoveItems`/`RemoveItem`, `AddItem` (for Undo), and `UpdateCompletion`.

`UserListPolicy#update?` stays owner-only. `destroy?` becomes "(owner or global admin) and not
`default?`". It keeps today's admin clause and its test, and adds the default-list refusal. Controllers
load through `current_user.user_lists` so a non-owner gets a 404 before the policy runs. All
actions call `prevent_caching` and use standard meta CSRF.

### Increment 1

**Dashboard (`/my/lists`).**

- A **+ New list** button opens a dialog with name, description, Make public, and the type picker on
  music. It posts to a new HTML create action. On success it redirects to the new list's page. On
  failure it re-renders the dialog's errors as a Turbo Stream (see the project rule that form
  failures are turbo-streams).
- The Favorites card gets one line: "Counts toward the site rankings".

**List page (`/my/lists/:id`).**

- **View modes:** Grid and Table only. A migration moves `list_view` rows to `grid_view` (2 in dev).
  The enum drops `list_view`. Integer 0 stays unused, and the builder must not renumber
  `table_view: 1, grid_view: 2`. The list-view branch of `UserLists::Show::ItemComponent` and its
  label go. A `?view_mode=list_view` param falls through to the list's stored mode.
- **Sort:** Your order (`position`, default), Recently added (`created_at DESC, id DESC`, the same
  as the API's `added`), and Ranking (when available). CSV follows the chosen sort, as today.
  "Recently added" applies to every list type.
- **Finish dates:**
  - Grid shows quiet text under the card when there is a date, and nothing otherwise.
  - Table's Finished cell shows the date, or "Add date" for the owner. Both are buttons styled as
    text that open `CompletionDialogComponent`. Non-owners see plain text.
  - All "Edit completion date for &lt;title&gt;" visible text goes. The control's accessible name keeps
    the title, e.g. `aria-label="Finish date for Stoner: Mar 3, 2026"`, so screen-reader users and the
    tests can still target a specific book.
  - After a save, the dialog's success path updates only that row, with no frame reload and no
    scroll jump. That applies the anti-goal to the existing dialog too.
- **Edit list** button in the toolbar, owner only. In increment 1 it links to the increment 2 route,
  so it ships with increment 2. Builder's call: either hide it until then or ship the two
  together.
- **Favorites note** above the items, on Favorites lists only.

### Increment 2: Edit list page (`/my/lists/:id/edit`)

Owner only (404 otherwise). It is paginated at 100 per page, in stored position order whatever sort
the list page used. Path-based pagination is the same as the show page's.

**The owner sees every item, provisional books included (my call).** That matches the owner's list
page today: `MyListsController#show` applies `catalog_items` only for non-owners. Positions are
therefore contiguous on the edit page (1…item count). A drop's target is the stored position of the
row it lands next to, Move to bottom is the item count, and Move to position accepts 1…item count,
the same range `MoveItem` validates. The API keeps hiding provisional books from its owner reads, as
#510 decided. That difference already exists and is not changed here.

**Details form** (top). Name (locked and greyed out with "Built-in lists keep their names" on
default lists), description, Make public, and its own Save. A failure re-renders the form's errors
as a Turbo Stream. On Favorites, the rankings note sits above the form.

**Rows.** Each row has:

- a position badge with the stored position
- a cover, title, and by-line
- on a list with completion dates, the date as quiet text ("Finished Mar 3, 2026" or a faint "No
  finish date", worded per list type as in Goal 6)
- a ⋯ menu, a ✕ remove button, and a drag handle

The ⋯ menu offers:

- Move to top
- Move to bottom
- Move to position… (a small inline number input or dialog, range 1…item count)
- Set finish date… (lists with completion dates only, worded per list type; it opens the existing
  dialog)

**Moves.**

- Drag uses SortableJS, the app's first drag library (`yarn add sortablejs`, bundled by Rollup), with
  a handle so touch scrolling still works. A drop sends the item's new absolute position, computed
  from the neighbouring row's stored position. Dragging works within the current page only.
- Menu moves send the absolute target position.
- Each request is a form-encoded PATCH to a new owner-only item endpoint that calls
  `UpdateItem.call(item:, position:)` and responds with a Turbo Stream that morphs the rows
  container and the pager. When the target lies off the current page (Move to bottom, or position
  250 from page 1), the row leaves the page and a toast says where it went ("Moved to #250").
- Any real move sets `manually_ordered`. `MoveItem` does this already, and it is the hook that
  switches a Favorites ballot to positional scoring.

**Remove.**

- ✕ removes the row through `RemoveItem` and shows a toast with **Undo**.
- Undo puts the item back with its old position and finish date in one owner mutation. That is
  `AddItem` then `UpdateItem(position:, completed_on:)`, or a dedicated restore service if the
  builder prefers.
- Undo must not trigger the Read → Reading transition in reverse in a surprising way. Removing a
  book from Read and undoing it should leave the member's lists exactly as they were.
- The toast lasts long enough to read, about 8 seconds. Undo after it is gone is not supported.

**Delete list** sits at the bottom of the page on custom lists only. It asks for confirmation,
deletes, and redirects to the dashboard with a notice. On default lists it is absent, and a forced
request is refused by policy.

**No-flicker requirement.** Every write on this page (move, remove, undo, date) answers with a
Turbo Stream that morphs in place. None navigates, reloads a frame, or changes the scroll position.
The builder must verify this in a real browser, not just in tests.

**Concurrency.** Two tabs moving items on the same list both go through `OwnerMutation`'s owner
lock, so the stored order stays consistent. The second tab's numbers may be stale until its next
write morphs them. That is acceptable.

### Accessibility

Every drag has a non-drag equivalent in the ⋯ menu, as WCAG 2.2 SC 2.5.7 requires; keyboard support
alone does not satisfy that rule. Menus, dialogs and toasts follow the daisyUI patterns already used
in the app. The ✕ and ⋯ buttons get accessible names that include the title.

## Constraints

- `MyListsController`, the routes and the components are shared by all three live domains. Music
  songs lists are always tabular, and their rich song row (`Music::Songs::ListItemComponent`) must
  still render. The edit page needs a sensible row for songs and albums as well as books and games.
- daisyUI 5 / Tailwind 4 conventions apply. Turbo-frame trapped links apply: the list page's
  `list_items` frame has `target: "_top"`.
- The add-to-list widget's cached state (localStorage) is re-checked only when the
  `tg_state_mark` cookie changes, or hourly. Touching the user does NOT invalidate it.
  Every web write that changes lists or memberships (create, rename, delete, remove,
  restore) must call `mark_user_state_changed`, as the JSON writes do. Moves change
  only positions, which that state doesn't hold. Do not add localStorage poking.
  (Corrected after PR #514's Codex review; the original text said touching the user
  was enough.)
- The existing E2E test `e2e/tests/books/account/reading-goals.spec.ts` targets the old "Edit
  completion date for &lt;title&gt;" button and dialog name. It must be updated to the new control.

## Testing

- Unit tests for the new list services (create, update, delete): the default-list refusals, name
  rules, and per-domain subclass resolution.
- Policy tests for `update?` and `destroy?`.
- Controller tests for each new action. They cover owner and non-owner (404), a default-list
  rename or delete refused, a bad position, the stream response, and the `list_view` param fallback.
- The API's existing tests pass unchanged.
- Playwright: a books spec for the dashboard create and list-page dates and sort (increment 1), and
  a books spec for the edit page: drag, Move to position, remove + Undo, Set finish date, rename,
  delete custom, and no delete on a built-in (increment 2). One spec should assert that the scroll
  position is unchanged after a move on a scrolled page.

## Left to the builder

Service and class names; the item endpoint's route shape; how Move to position collects the number
(inline input vs. small dialog); the toast component used for Undo; whether increment 1 ships the
Edit button hidden or both increments ship together; copy for each domain's Favorites noun.

## Addendum (2026-11-18): Edit page design pass

Shane reviewed the built Edit page and found the ⋯ menu broken-looking (no hover, no pointer
cursor, an inline position input crammed into it) and the details form sloppy (full-width
description, no grouping). Three layouts were mocked: A (two columns, sticky details card),
B (one narrow column, details card above the list), C (list first, details in a dialog). I
recommended C; **Shane picked B.**

**Layout (B).**
- A single column, `max-w-3xl` (about 720px), centred.
- Header: "← Back to list", then the list's name as the `h1`, with a "Built-in" badge (lock
  icon) on default lists.
- A white card (`card bg-base-100 shadow-sm`) holds:
  - name and a **Public toggle** (daisyUI `toggle`, replacing the checkbox) on one line
  - the description below them
  - Save at the bottom right
  - "Delete list" at the bottom left, in muted red, on custom lists only

  Default lists show the name disabled with "Built-in lists keep their names."
- Below the card, one line holds the item count ("127 books") and the pager, followed by the
  rows.

**Rows.**
- Softer position badges (`badge-ghost`/`bg-base-200`, not neutral black).
- The finish date sits on the by-line ("Leo Tolstoy · Finished Mar 3, 2026"), or the faint
  "No … date".
- ⋯ ✕ ⠿ stay on the right.

**The ⋯ menu.**
- It must follow daisyUI 5's `menu` contract: each `<li>`'s direct child is the `<button>`.
  daisyUI styles only `li > *`, so the forms `button_to` generates broke hover, padding and the
  pointer cursor.
- The action forms are hidden elsewhere in the row, and each button targets its form with the
  HTML `form` attribute.
- Items, each with a lucide icon: Move to top, Move to bottom, Move to position…, then a
  divider, then Set <label> date… (lists with completion dates only).

**Move to position…** opens a small dialog, built like the completion-date dialog:
- title "Move “<title>”" and the line "Currently #N"
- a number input labelled "New position (1–<count>)", required
- Cancel and Move buttons
- it posts to the existing move endpoint with `page`

The inline number form in the menu goes away.

**Pointer cursor (my call).** Tailwind v4's preflight gives buttons `cursor: default`. The
books, music and games stylesheets get Tailwind's recommended base rule:
`button:not(:disabled), [role="button"]:not(:disabled) { cursor: pointer; }`.

**Keyboard focus (my call; this closes the two parked follow-ups).**
- After a ⋯ menu action, focus moves to that item's row container (`tabindex="-1"`). Today it
  is blurred to `<body>`.
- After a date save on the list page, focus moves to the replacement opener once the stream
  has rendered. Today it is lost.
