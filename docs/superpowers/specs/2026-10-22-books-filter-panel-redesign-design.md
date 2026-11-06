# Books filter panel redesign

Date: 2026-10-22. Status: draft for owner review.

Supersedes parts of `2026-08-05-books-filters-rework-design.md` (the modal's level-1 layout, the
Category axis, the pane state model). Everything in that spec not contradicted here still holds,
in particular the URL grammar, the caps, the crawl policy, and the browse pages.

## Why

The filter on the books front page is, in the owner's words, "probably the most useful feature
of the site". People come to find the best books, and most of them only want certain genres or
more modern books. Genre is the most common filter, then publication date. Subject, setting and
origin are rarely used. Audience (Children's, Middle Grade, Young Adult) was added as a category
type on 2026-10-17 and has no proper place in the filter yet.

What is wrong today:

1. **The list jumps.** Ticking a search result in the Category or Origin pane either moves the row
   to the top of the scroll area or scrolls the area to the bottom. Root cause, reproduced in a
   browser:
   - `toggle()` in `app/javascript/controllers/books/filter_controller.js` (~l.129-159) hoists a
     checked search result. If it has no twin in the 24-row popular list, it is `appendChild`ed
     into the pane's Selected container, which sits at the top of the scroll area: "moves to
     the top".
   - If it has a twin, the twin is checked and `twin.focus()` scrolls the browser to it. Popular
     rows sit below the search results, so the scroll area jumps to the bottom (measured
     `scrollTop` 0 → 497, its maximum): "scrolls to the bottom".
2. **Category search results look random.** `CategorySearchQuery` matches `alternative_names` by
   substring and orders by `item_count`. Aliases hold junk left over from category merges, so
   "fantasy" returned Eroticism, Games and Baseball.
3. **Subjects and settings are hidden.** The only way to reach them is the Category search box.
   They have no row of their own, so nobody discovers they exist.
4. **Audience has no group.** `FilterFacetsQuery#genre_facet` mixes audiences into the genre list
   by count. The genre-cleanup spec (`2026-10-17-books-genre-cleanup-design.md`, ~l.357) asked
   for a separate group.
5. **The trigger is weak.** It is a `btn-sm` "Filters" button. With no filters applied it looks
   "small and out of place".
6. **Single-year browsing is invisible.** `/the-greatest-books/of/2024` ("…of 2024") already
   works when From and To are equal, but nothing tells people they can do that.
7. **Advanced search is unreachable from the filter.** Saved searches (`/searches/new`) are only
   linked from the signed-in "My Books" menu. A signed-out visitor who finds the URL is bounced
   to the front page with no message.

## Goals

- Fix the jumping in every pane: ticking a box never moves a row and never scrolls anything.
- One row per filter type on the first page, ordered by how often people use them.
- Make the common case (a genre, maybe an era or a year) quick and obvious.
- Fit comfortably on a phone. The panel is a bottom sheet there, and its action buttons are always
  reachable.
- Show a live result count on the main button.
- Link to advanced search.

## Non-goals

- No change to the filter URL grammar, the canonical paths, `FilterPath`, `FilterTitle` or the
  robots/crawl policy. Every existing filter URL keeps working and keeps its title.
- No change to the caps: 6 categories across all four category types combined, 10 countries.
- No change to how filters combine. Categories AND together, countries OR, the year range is
  inclusive.
- No exclude filters, no OR between genres, no language or length filters. Those live in advanced
  search.
- No desktop sidebar. Desktop uses the same panel, as decided on 2026-08-05.
- Music and games are untouched. None of this code is shared with them.
- No cleanup of the junk `alternative_names` data. Search ranking works around it here.
- Advanced search is linked to, not pre-filled from, the current filters.

## Anti-goals

These would make the work a failure even if it technically ships:

- Any row moves or the scroll area jumps when something is ticked or unticked.
- An existing indexed filter URL changes, redirects or loses its title.
- The phone panel needs scrolling just to reach the Show/Clear buttons.
- Opening the panel on an already-filtered page and pressing Show drops the applied filters.
  This bug shipped once: form state lived inside a lazily loaded frame (see Constraints).

## The design, as decided by the owner

Mockups are in `.superpowers/brainstorm/` (gitignored, local only):
`modal-first-page.html` (option "One row per type"), `trigger-empty-state.html`,
`inner-pages.html`, `published-single-year.html` (option "A row of recent years").

### Trigger button

Left-aligned, where the filter bar sits today. The CSV button stays on the right.

- Normal size, not `btn-sm`, with a filter icon.
- With no filters applied it reads **"Filter books"**.
- With filters applied it reads **"Filters"** plus a badge with the number of active filters. The
  count is all selected categories plus all selected countries, plus 1 if a year filter is set.
- The removable chips stay: on desktop beside the button, on phones wrapping onto the next line
  below it. Each chip removes one filter, as today.

### Panel, first page

Same `<dialog>` everywhere: a bottom sheet on phones (`modal-bottom`), centred from `sm` up. The
first page is six rows, in this order:

1. **Genre**
2. **Published**
3. **Audience**
4. **Origin**
5. **Subject**
6. **Setting**

Each row shows its current selection ("Fantasy", "Fantasy, Horror", "Since 2000", "Any") and
opens that type's page. Below the rows is an **Advanced search** link to `/searches/new`. It is
the same link for everyone, because the front page is edge-cached and identical for every
visitor.

### Advanced search intro page for signed-out visitors (owner's decision)

Today a signed-out visitor who follows that link hits `require_signed_in!`, which redirects to
`/` with a flash alert. On books, `/` is this same front page, and public layouts render no flash,
so the link would look broken. Port the old site's behaviour instead (legacy
`admin/app/views/saved_searches/account_required.html.erb`, rendered by
`check_authentication` in its `SavedSearchesController`):

- For a signed-out visitor, `GET /searches` and `GET /searches/new` (and the paginated index)
  **render an "Advanced Search" intro page with status 200** instead of redirecting. The other
  actions keep `require_signed_in!` as they are.
- The page explains the feature: build and save complex filters, combining the criteria the new
  saved-search form actually supports. Take the list from the form, not from the legacy copy:
  fiction/nonfiction, length, years, genres with AND/OR and exclude, languages, countries of
  origin, hide books I've read, and so on. Saved searches can be revisited later. It says a free
  account is needed.
- A **Login** button opens the existing `login_modal`. After sign-in the page reloads, using the
  existing reload-after-auth hook (`reloadAfterAuth` in `authentication_controller.js` /
  `data-reload-after-auth`), so the visitor lands on the form or their list.
- The controller already sends `prevent_caching`, so rendering per-visitor content here is safe.
- Saved searches are gated by `require_domain_support!`. The intro copy is written for books. If
  another domain supports saved searches, it gets equivalent copy or keeps today's redirect; that
  is the builder's choice, but no domain may show books copy.
- Public copy: run it through the `avoid-ai-writing` skill.

A footer pinned to the bottom of the panel holds **Clear** and the main button, **"Show N
books"**. It stays visible on every page of the panel and does not scroll with the content.
"Cancel" disappears; closing the dialog (backdrop, Escape, or a close control) discards unapplied
changes, as `discard()` does today.

**Clear** (design author's call) resets every pending selection in the panel, on all six types,
whichever page you are on. The count then updates and nothing is applied until Show. It is a
Stimulus action, not today's link to the unfiltered page. Removing a single applied filter in one
tap is what the chips on the page are for.

### Panel, type pages

Each page has a Back control at the top that returns to the first page, with the same pinned
footer.

**Genre and Origin: the full list.**
- Every option with at least one matching ranked book under the currently applied filters, biggest
  count first, with counts. After the genre cleanup that is about 83 genres; origins run to about
  250 countries.
- Selected options are included in the list at their natural position, checked. The facet query
  currently omits them, so that has to change.
- The search box filters the rendered list on the client as you type, with no server round trip.

**Audience: three checkboxes.** Children's, Middle Grade, Young Adult (fixed by the genre-cleanup
spec), with counts. No search box.

**Subject and Setting: popular list plus search.**
- About 4,100 subjects and 3,800 settings have ranked books. The page shows the **25 most common**,
  with counts, and a search box that queries the server for the rest.
- Search is limited to the page's own type. It ranks name matches above alias matches, then by
  ranked count. `Books::BrowseQuery.search` (from the `/categories` page, PR #399) already ranks
  this way and is the model *for ordering*.
- Search results are limited to categories that have at least one book under the **currently
  applied** filters, the same set the popular list is drawn from (design author's call). Otherwise,
  with Fantasy applied, a subject with no Fantasy books could be ticked and give "Show 0 books".
  `BrowseQuery.search` counts over the whole ranking, so this is a new query, not a reuse. Keep
  the name match inside the counting subquery, as `BrowseQuery` does: that took the per-keystroke
  cost from ~760 ms to ~90 ms. Budget: under ~300 ms on the dev database for a filtered search.
  If it cannot get there, fall back to `BrowseQuery.search`'s unfiltered set and say so in the PR.
- **Anything selected on this page shows as a removable chip under the search box,** outside the
  scrolling list. That is where a pick found by search lives once the search is cleared. Ticking a
  row in the popular list or in search results checks it in place *and* adds the chip. Nothing
  else moves.
- Search results show no counts, as today: a result list must not show a different number for
  the same row than the facet list does.

**Published.** Top to bottom. The owner reordered the mockup's version: eras come before single
years, so this text wins over `published-single-year.html`.
1. **Eras.** One-tap buttons: Since 2000, 1950–1999, 1900–1949, 1800s, Before 1800.
2. **Best of a single year.** One-tap buttons for the last five full years, rolling with the
   calendar: in 2026 that is 2025, 2024, 2023, 2022, 2021.
3. **From / To** number boxes, as today, with the hint "Same year in both boxes = just that year.
   Minus sign for BC."

Tapping an era or a year fills the From/To boxes; the boxes are what gets submitted. At most one
era or year button looks selected, and only when the boxes match it exactly. Editing a box clears
the button highlight.

### Live count

The main button shows how many ranked books the pending selection would return. It updates after
each change, debounced (about 300 ms). While a count request is in flight, the button keeps its
last number. If the count is 0, the button still works and reads "Show 0 books". The page already
explains an empty result.

### Fixing the jump

The root cause is that a checked row is physically moved (hoisted) or focused somewhere else. The
rule in the new design is that **a checkbox is never moved, re-parented, or focused
programmatically after the user ticks it.**

- Genre, Origin and Audience never need to move anything, because the full list is on the page.
- Subject and Setting represent "selected" with chips that sit outside the scrolling list.
- The form value for a selected category must survive its search-result row disappearing when the
  search changes. So the submitted input belongs to the chip (or to an always-present hidden
  input), not to the transient search row. That is the builder's call (see below), as long as the
  form never submits a value twice and never loses one.

## Constraints and landmines

From the August build (`docs/superpowers/specs/2026-08-05-books-filters-rework-design.md` and the
`books-public-filters` project notes):

- **Form state must never live only inside a lazily loaded turbo-frame.** Applied filters must be
  in the initial server response, outside any lazy frame. The regression guard must be structural:
  assert the inputs exist outside the frame. An E2E timing check was vacuous last time.
- **Scope `data-*` selectors by input type.** A shared `data-axis` once matched the search box as
  well as the checkboxes and broke the "count the checked ones" logic.
- **Every user-facing count is over `RankedBooksQuery`'s set**, never `categories.item_count` or
  `books_countries.book_count`. Those are catalog counter caches and disagree wildly (Fiction
  65,073 vs 15,875).
- The ranked list page is edge-cached for 6 hours. Anything per-request goes through uncached
  endpoints: the pane bodies (already lazy, under `/filters/...`), the new count endpoint, and the
  search endpoint.
- `CategorySearchQuery` is shared with admin, saved searches and global canon. Change its default
  behaviour only if every caller wants the change. Otherwise scope through arguments or use
  `BrowseQuery.search`.
- Facet asymmetry stays: genre counts keep the category filter applied (drill-down), country
  counts drop the country filter (alternatives). Audience, Subject and Setting counts follow genre
  (AND).
- Labels: "Origin", not "Country"; "Setting", not "Location" (owner, 2026-08-05). Subject filter
  titles read "on X" and setting titles "Set in X". Neither changes.
- Turbo Frames trap links: anything inside a frame that links off-page needs `target: "_top"`.
- daisyUI 5 / Tailwind 4. Do not use the removed v4 classes (`form-control`, `label-text`, …). The
  lint test fails on them.
- The pinned footer must work inside daisyUI's `modal-box`, which sets its own `max-height` and
  `overflow-y: auto`. The scroll belongs to a content region inside the box, not to the box
  itself.

## Testing

- Component and controller tests per AGENTS.md: behaviour, not markup or copy.
- Query tests for the new per-type facets, the count, and the per-type search ranking. Search
  fixtures must include a category whose **alias** matches the query and one whose **name**
  matches, so that the name-first ordering test is not vacuous.
- `e2e/tests/books/filters.spec.ts` (19 tests) is rewritten. Fourteen of its selectors key off the
  old placeholder "Search genres, subjects, settings", which is going away. The new suite must
  cover at minimum:
  - **No-jump regression.** Search a subject, tick a result, and assert that the scroll area's
    `scrollTop` and the ticked row's position did not change. Repeat for a genre that is also in
    the full list (the old "twin" case).
  - Apply from an already-filtered page keeps the filters.
  - Single-year button → `/of/<year>` URL.
  - The live count changes after a tick.
  - The advanced search link is present. Signed out, it shows the intro page; the Login button
    opens the sign-in box.
- Controller test: signed out, `GET /searches/new` and `GET /searches` return 200 with the intro
  page, not a redirect. `POST /searches` signed out still redirects.
  - Phone viewport: the footer buttons are visible without scrolling on every panel page.

## Left to the builder

- How the six pages are built: one Stimulus controller or several, which lists are server-rendered
  versus lazily loaded, and the endpoint shapes for the count and per-type facets.
- Whether the full Genre and Origin lists load with the first page or lazily when their page
  opens.
- Exactly where the hidden inputs live, within the rule above.
- Icon choice, spacing and exact daisyUI components.
- First-page row hints, if any (today's Category row has "Genre, audience, subject, or setting").
- Whether the `/filters/categories` pane endpoint is reshaped or replaced.
