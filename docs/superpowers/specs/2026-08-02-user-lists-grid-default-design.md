# User Lists: Grid as the Default View — Design

**Date:** 2026-08-02
**Status:** Approved, not implemented
**Builds on:** `2026-08-02-books-user-lists-ui-design.md` (PR #198), which shipped the three view
modes and public list viewing

## Problem

A user list opens in **list view** — one full-width row per item, showing a small thumbnail, the
title/by-line heading, and the item's description. Grid is available behind the view switcher but is
not what anyone lands on, and when they do switch, the books grid looks nothing like the books grid
everywhere else on the site.

Two separate defects, one PR:

1. **The wrong default.** `view_mode` is a persisted per-list enum defaulting to `default_view`
   (list). 282,687 of 283,368 lists sit on it — not by choice, but because the legacy migration
   mapped legacy `NULL` (the old site's "user never picked one") onto it. Only 259 lists chose grid
   and 422 chose table.
2. **The grid does not match.** `UserLists::Show::ItemComponent` already renders the *identical*
   `Books::CardComponent` in `grid_view`, so the cards are not the problem. The **container** is:

   | Surface | Container classes |
   |---|---|
   | Books homepage, `/lists/:id`, `/author/:slug`, author all-books | `grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-6` |
   | My Lists grid view (`my_lists/show.html.erb:106`) | `grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6` |

   One column of 2:3 covers on mobile and four at `xl`, versus two and six. Books cards get roughly
   2.25× the linear size they were designed for. My Lists cards also carry no `#N` badge, because
   `listable_card` passes `index:` but not `rank:`.

Music and games are unaffected by (2): their main grids already use the same
`grid-cols-1 md:2 lg:3 xl:4` string My Lists uses.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Grid becomes the default for **every** domain, via one enum default | Music + games + movies hold 440 lists total. A per-subclass `default_view_mode` hook would be more machinery than the blast radius justifies. |
| D2 | One-time backfill of `default_view` rows to `grid_view` | Lossless today: legacy `NULL` → `default_view` means "never chose", and books My Lists is days old, so essentially nobody has deliberately picked List in the new app. Explicit grid (259) and table (422) choices are untouched. |
| D3 | Rename the enum member `default_view` → `list_view` | Integer values stay 0/1/2, so no extra data movement. `default_view` naming a mode that is not the default is a trap for a future reader. |
| D4 | Grid cards show the item's **stored list position** as the rank badge | Matches `/lists/:id` and matches what list view already prints ("12. Title"). Under `?sort=ranking` the badges are non-sequential — that is existing list-view behavior, not a regression. |
| D5 | The books grid container lives in **one constant** | `Books::CardComponent::GRID_CONTAINER_CLASS`, referenced by all five surfaces. "Looks exactly like the main grid" becomes structurally true rather than a coincidence that already drifted once. |
| D6 | List view stays | It is the only view that surfaces descriptions. |

## A. The default flips to grid

### `app/models/user_list.rb`

```ruby
enum :view_mode, {list_view: 0, table_view: 1, grid_view: 2}, default: :grid_view

# Switcher order and labels. Declared here rather than in the view so the default
# reads first without reordering the enum's integer mapping.
VIEW_MODE_LABELS = {
  "grid_view" => "Grid",
  "list_view" => "List",
  "table_view" => "Table"
}.freeze
```

### `app/views/my_lists/show.html.erb`

- Delete the local `view_mode_labels` literal (line 3).
- The switcher loop (line 49) iterates `UserList::VIEW_MODE_LABELS` instead of
  `UserList.view_modes.keys`, so it renders **Grid · List · Table**.

`MyListsController` is unchanged here: `params[:view_mode].presence_in(UserList.view_modes.keys)`
and `UserList.view_modes.key?(requested)` both still resolve correctly against the renamed member.

### Migration

One migration, both halves:

```ruby
def up
  change_column_default :user_lists, :view_mode, from: 0, to: 2
  execute "UPDATE user_lists SET view_mode = 2 WHERE view_mode = 0"
end

def down
  change_column_default :user_lists, :view_mode, from: 2, to: 0
end
```

`down` deliberately restores only the column default. Once the `UPDATE` runs there is no way to
distinguish a backfilled row from a deliberate grid choice, so reversing the data would corrupt the
259 lists that genuinely chose grid.

- **Dev:** ~282,687 rows. Single statement, brief table lock, seconds. **Snapshot first**
  (`bin/snapshot-dev-db.sh --label pre-grid-default`) — the books data exists only in dev.
- **Production:** ~440 rows. The books data has never been migrated to production.

This runs as a schema migration, not `rails runner`, so `.claude/hooks/block-destructive-db.sh` does
not block it. That hook is protecting against exactly the class of mistake this migration is a
deliberate instance of — do not work around it in any other way.

## B. `UserListMigrator::VIEW_MODE_MAP` must change with it

`Services::BooksMigration::UserListMigrator` is **idempotent on id** and maps legacy `NULL` → `0`.
Production has never run the books migration, so all 282,928 legacy books lists are still ahead of
it. Left alone, that run would upsert every one of them onto `list_view` and silently undo the
backfill.

```ruby
VIEW_MODE_MAP = {nil => 2, 1 => 1, 2 => 2}.freeze
```

Legacy `NULL` meant "user never chose, use the site default" — the old site's enum was literally
`default_view: nil` (`docs/old_site/user-lists-feature.md:77`). Retargeting it at the new site
default is the faithful mapping.

Update the comment above `VIEW_MODE_MAP`, which currently reads "view_mode's legacy default member
is NULL, not 0" — still true, but it now needs to say where NULL lands and why.

## C. Grid parity

### `app/components/books/card_component.rb`

```ruby
# The grid this card is designed for. Every books grid must use it, or My Lists
# drifts away from the homepage again.
GRID_CONTAINER_CLASS = "grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 " \
  "lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-6"
```

Four public views drop their inline literal for it:

- `app/views/books/ranked_items/index.html.erb:22`
- `app/views/books/lists/show.html.erb:36`
- `app/views/books/authors/show.html.erb:24`
- `app/views/books/authors/all_books.html.erb:23`

### `app/components/user_lists/show/item_component.rb`

```ruby
DEFAULT_GRID_CONTAINER_CLASS =
  "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6"

# Books covers are 2:3 and tile far denser than square album art, so the books
# grid is its own shape. Everything else keeps the shared four-column grid,
# which already matches the music and games ranked grids.
def self.grid_container_class(listable_class)
  if listable_class.to_s == "Books::Book"
    Books::CardComponent::GRID_CONTAINER_CLASS
  else
    DEFAULT_GRID_CONTAINER_CLASS
  end
end
```

`ItemComponent` already references `Books::Book`, `Music::Album` and `Games::Game` directly, so this
introduces no new cross-domain coupling. It is a class method for the same reason `table_layout?` and
`card_capable?` are — the show view calls it once for the whole homogeneous collection.

**Tailwind scanning (verified, not assumed).** Moving a class string out of an `.erb` file and into a
`.rb` file is normally how classes get silently purged. All five stylesheets
(`application.tailwind.css` and `{books,music,games,movies}/application.css`) declare
`@source ".../app/components/**/*"` with no extension filter, so both constants are scanned. Keep
each class token whole within its line when wrapping the string — the scanner is a regex over raw
text and will not reassemble a token split across a `\` continuation.

### `app/views/my_lists/show.html.erb`

```erb
<% container_class = (@view_mode == "grid_view") ?
     UserLists::Show::ItemComponent.grid_container_class(@list.class.listable_class) :
     "space-y-6" %>
```

## D. Rank badge and the eager-load window

`ItemComponent#listable_card` gains the badge for books:

```ruby
when Books::Book then Books::CardComponent.new(book: listable, rank: position, index: index)
```

`index` is currently derived as `position - 1`, which is wrong under `?sort=ranking`: position is the
item's stored slot, not its place on the page, so `Books::CardComponent::EAGER_IMAGE_COUNT`
eager-loads six arbitrary covers instead of the six actually above the fold.

- `UserLists::Show::ItemComponent#initialize` gains an **`index: nil`** keyword. The default is
  `nil`, not `0`: `Books::CardComponent#above_fold?` is written as `index.present? && index <
  EAGER_IMAGE_COUNT`, so `nil` degrades to lazy/auto loading. Defaulting to `0` would mark an
  unknown position as above the fold, which is the exact failure its comment warns about, and it
  would silently do so in every existing component test.
- `my_lists/show.html.erb` switches both render loops (the `<tbody>` one and the card container one)
  to `each_with_index` and passes it. Only the books card consumes it; the table row ignores it.

Books is the only card that consumes `index`; `Music::Albums::CardComponent` and
`Games::CardComponent` take neither `rank:` nor `index:` and are unchanged.

## E. Rename sweep

Mechanical `default_view` → `list_view` across:

| File | Occurrences |
|---|---|
| `app/models/user_list.rb` | 1 (the enum) |
| `app/views/my_lists/show.html.erb` | 1 (removed with the label literal) |
| `test/models/user_list_test.rb` | 4 |
| `test/controllers/my_lists_controller_test.rb` | 8 |
| `test/components/user_lists/show/item_component_test.rb` | 7 |
| `test/lib/services/books_migration/user_list_migrator_test.rb` | 2 (also flip to `grid_view`, §B) |
| `docs/features/user-lists.md` | 1 |
| `docs/specs/user-lists-02f-list-management-and-editing.md` | 1 |

**Leave `docs/old_site/user-lists-feature.md` and `docs/specs/completed/` alone.** Those describe the
legacy app and shipped history; rewriting them would falsify the record. The old site's
`default_view: nil` in particular is the evidence for §B.

Existing `?view_mode=default_view` URLs stop matching `presence_in` and fall through to the list's
persisted mode — a soft landing. These URLs are days old and linked from nowhere.

## Testing

`bin/rails test` and `bundle exec standardrb` from `web-app/`. CI eager-loads (`CI=true`) and is
stricter than a local run. Controller tests assert status and behavior only, never HTML or copy.

New / changed assertions:

- `test/models/user_list_test.rb` — `view_mode` defaults to `grid_view` on new records and after
  save; `list_view` maps to 0
- `test/lib/services/books_migration/user_list_migrator_test.rb` — a legacy row with `view_mode`
  `NULL` lands on `grid_view`; legacy `1`/`2` still land on `table_view`/`grid_view`
- `test/components/user_lists/show/item_component_test.rb` —
  `grid_container_class("Books::Book")` returns `Books::CardComponent::GRID_CONTAINER_CLASS` and
  anything else returns `DEFAULT_GRID_CONTAINER_CLASS`; a books item in `grid_view` renders the
  `#N` badge carrying the item's position
- `test/controllers/my_lists_controller_test.rb` — a list that has never had a view mode set renders
  in grid; `?view_mode=list_view` still persists for the owner and still does **not** persist for a
  non-owner
- `test/components/books/card_component_test.rb` — unchanged behaviour, but confirm the card still
  renders without `rank:` (the constant extraction must not disturb it)

### E2E

`e2e/tests/books/account/my-lists.spec.ts:32-35` clicks **Grid** to prove the switcher works. Grid is
now the landing state, so that assertion proves nothing — flip it to click **List** and assert
`view_mode=list_view` in the URL.

`e2e/tests/books/account/add-to-list.spec.ts` and `e2e/tests/books/public-list.spec.ts` exercise the
grid cards' add-to-list widget. The `#N` badge is a sibling of the widget inside the same
`card-body`, and the widget already sits in a `relative z-10` wrapper above the title's
`after:absolute` stretched link — the badge changes nothing there, but these specs are the only guard
if it does.

No new spec file: this changes the shape of surfaces that already have coverage.

## Out of scope

- **Pagination.** My Lists is already `limit: 100`, matching the books public pages.
- **List and table views themselves.** Only the switcher's order and one member's name change.
- **`persist_view_mode`.** Unchanged; the owner still writes their choice on an explicit param.
- **Movies.** Out of scope project-wide.
- **A nullable `view_mode` with NULL meaning "site default".** Considered and rejected (D2). It
  preserves the never-chose signal forever, but the whole population of that signal is being
  consumed by this one change, and a future flip is a second one-statement migration.

## Docs to update on completion

- `docs/features/user-lists.md` — the view-mode section (line 242): `list_view` is the new name,
  `grid_view` is the default, and the switcher order is Grid · List · Table
- `docs/specs/user-lists-02f-list-management-and-editing.md:136` — the `default_view` reference in
  the Phase B `completed_on` editor plan
