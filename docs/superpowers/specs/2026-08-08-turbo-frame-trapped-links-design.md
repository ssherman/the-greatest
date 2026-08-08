# Turbo-frame-trapped links on `/my/lists/:id`

**Date:** 2026-08-08
**Branch:** `worktree-turbo-frame-trapped-links`

## Problem

Clicking a book on a custom user list show page in production renders "Content missing"
instead of the book page.

`app/views/my_lists/show.html.erb:70` wraps the list items in `turbo_frame_tag "list_items"`.
Turbo scopes every `<a>` inside a frame to that frame, so the click fetches `/book/:slug`,
finds no `list_items` frame in the response, discards the document, and writes "Content
missing" into the frame.

## Audit

The bug is confined to `/my/lists/:id`, but on that page it affects every listable type,
not just books:

| View mode | Listable | Link source | Escapes the frame? |
| --- | --- | --- | --- |
| List | `Books::Book` | `UserLists::Show::ItemComponent#title_link` | no |
| List | `Music::Album` | `#title_link` → `link_to_album` | no |
| List | `Games::Game` | `#title_link` → `link_to_game` | no |
| List, Grid | `Music::Song` | `Music::Songs::ListItemComponent` (song + artist links) | no |
| Grid | `Books::Book` | `Books::CardComponent` title link | no |
| Grid | `Music::Album` | `Music::Albums::CardComponent` | yes — sets `_top` |
| Grid | `Games::Game` | `Games::CardComponent` | yes — sets `_top` |
| Table | any | titles render as plain text, no anchors | n/a |

Everywhere else is already correct:

- `music/albums/lists/show.html.erb` and `music/songs/lists/show.html.erb` use the same
  `list_items` frame, but every link inside them carries `data-turbo-frame="_top"`.
- Books and games public `/lists/:id` have no frame at all.
- The books filter panes (`books_filter_pane_*`, `books_filter_results_*`) contain
  checkboxes plus links that already set `_top`.

## Fix

Flip the frame's default instead of patching each link.

`app/views/my_lists/show.html.erb:70`:

```erb
<%= turbo_frame_tag "list_items", target: "_top", data: {turbo_action: "advance"} do %>
```

With `target="_top"`, every link inside navigates the full page unless it opts back in.
The two pagy navs (lines 81 and 114) opt back in so paging stays in-frame:

```erb
<%== @pagy.series_nav(anchor_string: 'data-turbo-frame="list_items"') %>
```

This is the `anchor_string` pattern `admin/ranked_items/index.html.erb` and
`admin/list_items/index.html.erb` already use.

Nothing else inside the frame is a link. `UserLists::CardWidgetComponent` renders a
`<button>`, `UserLists::ModalComponent` is rendered by the domain layouts, and the sort /
view-mode / CSV-download links sit above the frame. `Books::CardComponent`,
`ItemComponent#title_link` and `Music::Songs::ListItemComponent` are left untouched and
all begin working.

`user_list_add_item_controller.js` is unaffected: `_refreshList` either sets `frame.src` or
calls `frame.reload()`, and neither reads the `target` attribute.

### Why frame-level rather than per-link

Per-link `data-turbo-frame="_top"` is what music and games cards already do, and it is
exactly the convention that failed here — books and songs were added later and did not
inherit it. The frame attribute makes the safe behaviour the default, so a component
dropped into the list in the future cannot reintroduce the bug.

## Regression guard

Split in two so the analysis is testable on its own:

1. `test/support/turbo_frame_links.rb` — `TurboFrameLinks.trapped_candidates(html, host:)`,
   a pure, HTTP-free function returning the anchors whose click would stay inside a frame.
2. `assert_no_frame_trapped_links(path)` on the `ActionDispatch::IntegrationTest` reopening
   in `test/test_helper.rb`, alongside `sign_in_as` — the thin layer that supplies requests.

The split matters: once the page is fixed the assertion finds zero links to follow
anywhere in the suite, so without unit tests against known-bad HTML a broken analyser would
pass silently everywhere.

Behaviour: for every `<a href>`, walk up to its nearest enclosing `<turbo-frame>`. The
anchor's effective Turbo target is:

```
a["data-turbo-frame"] || frame["target"] || frame["id"]
```

If that value is not `_top`, GET the href (following redirects) and fail unless the
destination is 2xx **and** contains `<turbo-frame id="<effective>">`.

Skipped anchors: those with no enclosing frame, `data-turbo="false"`, fragment-only /
`mailto:` / `tel:` / `javascript:` hrefs, and absolute URLs on a different host. Candidates
are deduped, so a 25-item list costs a handful of extra GETs.

Note there is deliberately **no** skip for non-HTML extensions such as `.csv`. A frame-scoped
link to a CSV is just as broken as one to a book page, and skipping it would hide a real
defect; the CSV download link on this page escapes via `data-turbo="false"` already.

Limits, stated deliberately:

- Anchors only. A `<form>` inside a frame is the same bug class, but submitting arbitrary
  forms in a test is not safe, so forms are out of scope.
- The assertion issues its own requests and therefore clobbers `response`. It is called as
  its own test case, never appended to an existing one.

### Call sites

`test/controllers/my_lists_controller_test.rb` — `list_view`, `grid_view` and `table_view`
against all four listable types, each on its own domain host. Fixtures already exist with
items:

| Fixture | Listable |
| --- | --- |
| `regular_user_music_albums_favorites` | 3 × `Music::Album` |
| `regular_user_music_songs_favorites` | 1 × `Music::Song` |
| `regular_user_books_favorites` | 2 × `Books::Book` |
| `regular_user_games_favorites` | 1 × `Games::Game` |

`test/controllers/music/albums/lists_controller_test.rb` and
`test/controllers/music/songs/lists_controller_test.rb` — these pages are correct today;
the guard pins them so they stay that way.

## E2E

Two tests appended to `e2e/tests/books/account/my-lists.spec.ts`. The `books-account`
Playwright project and its stored books auth already exist, so no config change is needed.

From the dashboard, open `My Favorite Books`, then:

1. In grid view, click the first item title.
2. Switch to List view and click the first item title again.

Each asserts the URL matches `/book/`, the `<h1>` equals the clicked title, and
`Content missing` has zero matches on the page.

## `CLAUDE.md`

Add under **Frontend**:

> **Turbo Frames trap links.** Every `<a>` inside a `turbo_frame_tag` navigates *that
> frame*, so a link to another page renders "Content missing". Put `target: "_top"` on any
> frame whose contents link off-page, and opt pagination back in with
> `@pagy.series_nav(anchor_string: 'data-turbo-frame="<frame_id>"')`.
> `assert_no_frame_trapped_links` guards this.

## Files touched

1. `web-app/app/views/my_lists/show.html.erb`
2. `web-app/test/support/turbo_frame_links.rb` (new)
3. `web-app/test/support/turbo_frame_links_test.rb` (new)
4. `web-app/test/test_helper.rb`
5. `web-app/test/controllers/my_lists_controller_test.rb`
6. `web-app/test/controllers/music/albums/lists_controller_test.rb`
7. `web-app/test/controllers/music/songs/lists_controller_test.rb`
8. `web-app/e2e/tests/books/account/my-lists.spec.ts`
9. `CLAUDE.md`

## Verification

Work happens in the git worktree `.claude/worktrees/turbo-frame-trapped-links` on branch
`worktree-turbo-frame-trapped-links`, with `web-app/.env` and `web-app/config/master.key`
symlinked in from the main checkout (both are gitignored). The test database and the Ruby
version are shared with the main checkout and need no setup.

```bash
cd web-app
bin/rails test
bundle exec standardrb
yarn build:all && bin/rails server        # not bin/dev — it self-terminates without a TTY
yarn test:e2e --project=books-account
```
