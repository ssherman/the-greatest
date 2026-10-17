# Books `/categories` page — design

**Date:** 2026-10-17
**Status:** draft, awaiting approval
**Extends:** `2026-08-07-books-legacy-genres-routes-design.md` (which ported the legacy `/genres`
grammar) and `2026-08-05-books-filters-rework-design.md` (which shipped `/genres` itself).

## 1. Intent

The books site already has a category index at `/genres` (`Books::BrowseController#genres`). It has
three tabs (Genres, Settings, Subjects), shows ranked-book counts, sorts by count or name using
path segments, and edge-caches every view. Each card links to the ranked list filtered to that
category. What it does badly:

- **You can't tell which controls filter and which sort.** The type toggle (Genres / Settings /
  Subjects) and the sort toggle (Most books / Name) are two identical-looking button groups sitting
  side by side.
- **There is no search.** Subjects and Settings run to 1,619 and 909 visible cards, 120 per
  page. Finding "Betrayal" or "Lisbon" means paging or using the browser's find.
- **A place has no context.** "Georgia", "Lazio" and "Île-de-France" give no hint of where they are.
- **It lives at `/genres`,** which names one of its three tabs. Shane wants `/categories`.

People arrive both to browse and to find a specific category they already have in mind. The page has
to serve both.

The old legacy site's confusion is that its counts covered every book, not just ranked ones. That is
already fixed here: counts are ranked books from the primary ranking configuration, and they match
the list each card opens. This must stay true.

## 2. Goals

1. Move the page to `/categories`. Every existing `/genres/...` index URL 301s to its `/categories`
   equivalent.
2. Separate the type from the sort visually. The type becomes page tabs, and the sort becomes one
   labelled dropdown.
3. Add search that finds any category the page would show, including ones on later pages.
4. Under each child category's name, show where it sits (`Europe › France › Île-de-France`).
5. Look right on desktop and phone, using daisyUI 5 and Tailwind 4 idioms.
6. Add a "Categories" link to the books top nav.

## 3. Non-goals

- **Music and games.** Books only. A todo entry covers them (`docs/todo.md`, "Music and games").
  Don't contort the books code to be generic in advance. Keep it clean enough to lift later.
- **Category show pages.** A card links to the filtered ranked list, as now. There is no
  `/categories/:slug` page.
- **Browsing the place hierarchy** (drill-down pages, child previews on a card). Shane liked the idea
  of top-level cards that preview their children, but expects tall expanded cards to look bad. It is
  deferred, not rejected.
- **Changing what is counted, or the minimum.** Subjects and settings still need
  `config.x.books.browse_min_category_books` (5) ranked books to appear. Genres are exempt.
- **The `/countries` ("Book Origins") page's URL and content.** See §8 for how much of the redesign
  it picks up.

## 4. Anti-goals

- **A count that disagrees with the list the card opens.** Search results must use the same ranked
  count and the same minimum as the grid. `CategorySearchQuery` as the filter modal calls it gates on
  *all* books (`min_items_item_type`), not ranked ones, so it can't be reused unchanged.
- **Query-string URLs for anything cacheable.** Type, sort and page are path segments. Cloudflare
  caches on the path.
- **A new hostname or a broken `/genres` link.** `/genres` has had sitewide links on the legacy site
  for about a decade. Every old shape must land somewhere sensible with one 301.

## 5. Decided (by Shane)

- The URL becomes `/categories`, and `/genres` redirects to it. This reverses the August spec's "no
  redirect where avoidable". That reversal is deliberate.
- Counts stay ranked-only.
- Sort by count and by name both stay.
- Search is in.
- Filters and sorts are path segments, never query strings.
- Cards link to the main ranked list filtered by that category. No show pages.
- **Layout: keep today's cards** (mockup option C). Only the controls change: tabs for the type, a
  labelled sort dropdown and a search box. The denser one-line list (option A) was considered and
  not chosen.
- **Hierarchy: stay flat and show the parent chain** under the name (mockup option C), rather than
  drill-down or child previews.
- Books first. Music and games go to the todo list.

### Calls made while writing this (not Shane's; overridable)

- The URL words are `settings` / `subjects`, and genres is the bare `/categories`.
- Search spans all three types, with a neutral "Search categories…" label.
- The search endpoint uses `?q=` and is uncached.
- The parent chain shows on child genres as well as locations, in full, with no cap.
- Phones get 2 columns.
- The sort label "Name" is renamed "A–Z".
- `/countries` gets the new sort dropdown only.
- There is a top-nav "Categories" link.

## 6. Data (dev, 2026-10-17, primary ranking "May 2026", 21,390 ranked books)

| Type | Live | With ≥1 ranked | Shown (≥5 ranked; all genres) | Hierarchy |
|---|---|---|---|---|
| Genre | 171 | 159 | 159 | 17 children under 5 parents, 3 levels (Fiction › Speculative Fiction › Science fiction › Space Opera) |
| Location ("Settings") | 15,021 | 3,772 | 909 | Up to 6 levels; 21 shown roots (Europe, North America, Fictional Location, Asia…) |
| Subject | 10,708 | 4,135 | 1,619 | None |

- **A parent's count already includes its children.** Every location child tag also tags its parent
  (444,147 of 444,147 checked), so the parent chain needs no count work.
- No two shown locations share a name today. The chain is context, not a disambiguation fix, but it
  would also cover a future "Georgia" clash.

## 7. URLs

### New grammar

| Path | Shows |
|---|---|
| `/categories` | Genres, most books first |
| `/categories/settings` | Settings |
| `/categories/subjects` | Subjects |
| `/categories[/<type>]/sorted-by/name` | A–Z |
| `…/page/:page` | Pagination, on any of the above |

`<type>` is `settings` or `subjects`. Genres is the bare `/categories`, so the default has one URL.

The rules carry over from the existing grammar:

- Segments are regex-constrained, so `/categories/<anything>` can't grow an unbounded set of
  soft-duplicate URLs.
- `/page/1` and the query-string forms (`?filter=`, `?sort=`, `?page=`) 301 to the path form.
- Sorted variants are `noindex, follow` and canonicalize to the unsorted path.
- That redirect runs before `cache_for_index_page`, so a 301 never carries edge-cache headers.

The URL words are `settings` and `subjects` to match the tab labels. Internally the enum stays
`location` / `subject`. The mapping lives in one place: the path builder (today `Books::BrowsePath`).

### Redirects from `/genres`

| Old | New |
|---|---|
| `/genres` | `/categories` |
| `/genres/filtered-by/genre[...]` | `/categories[...]` |
| `/genres/filtered-by/location[...]` | `/categories/settings[...]` |
| `/genres/filtered-by/subject[...]` | `/categories/subjects[...]` |
| `/genres/sorted-by/:sort[...]` | `/categories/sorted-by/:sort[...]` |
| any of the above `/page/:page` | same page on the new path (page 1 dropped) |
| `/genres?filter=…&sort=…&page=…` | the matching `/categories` path, in one hop |
| `/genres/:id` (legacy show page) | **unchanged**: still 301s to `/the-greatest/<slug>/books` via `Books::LegacyCategoriesController` |

Each old URL redirects in **one** hop. `/genres/filtered-by/location/page/1` must not go to
`/genres/filtered-by/location` and then to `/categories/settings`. The `sort` values accepted are
the existing `book_count|name`.

`/genres/:id` must still be declared after every other `/genres` route (see the comment at
`config/routes.rb` around line 1071).

### Links to update

- Footer "Browse" column: "Genres" becomes "Categories" (`app/components/footer_component.rb`).
- The filter modal's "Browse all genres" link (`app/components/books/filter_pane_component.rb`).
  Point it at `/categories` and consider rewording it.
- New top-nav link "Categories" after Authors (`app/views/books/shared/_nav_links.html.erb`). The
  partial renders both the desktop bar and the mobile drawer.
- Card links: today the view hardcodes `"/the-greatest/#{record.slug}/books"`. Build them with
  `Books::FilterPath.call(categories: [record])`, the one place that grammar is spelled.

## 8. The page

The mockups from the brainstorm are in `.superpowers/brainstorm/` (gitignored, local only). The
chosen layout is `layout.html` option C, and the chosen location display is `locations-v1.html`
option C.

### Top to bottom

1. **Title**: "Book Genres" / "Book Settings" / "Book Subjects", as now.
2. **Tabs**: Genres · Settings · Subjects, as page tabs (daisyUI `tabs`) built as plain links
   inside a labelled `nav` (`aria-label="Category type"`), the active one `tab-active` plus
   `aria-current="page"`. No `role="tab"` or `tablist`: ARIA tabs promise panels and arrow-key
   behaviour that page links do not have, so links in a nav is the correct pattern. The active tab
   must differ by shape or underline, not color alone. Switching tabs keeps the current sort
   and drops the page.
3. **Toolbar row**:
   - a search box labelled "Search categories…" on every tab, because search covers all three
     types (see Search). A tab-specific label would misstate the scope.
   - a sort dropdown on the right reading "Sort: Most books ▾", with options *Most books* and *A–Z*
     (renamed from "Name").
   - The dropdown's options are **plain links** to the sorted paths, not a form, so each sort keeps
     a cacheable URL. Use a daisyUI 5 dropdown that opens without JavaScript (`<details>`, or the
     focus-based variant).
   - On a phone the search goes full width and the sort sits on its own line or beside it, whichever
     fits.
4. **Card grid**: today's `Books::BrowseCardComponent` look (name, count) with one addition:
   - **The parent chain**, a small muted line under the name. It is the full chain, root first,
     excluding the category itself, with no depth cap and no roots dropped. Examples: `Europe ›
     France › Île-de-France` on Paris; `Fiction › Speculative Fiction › Science fiction` on Space
     Opera. A deep location can show up to 5 ancestors, and the line wraps.
   - Top-level categories and all subjects show no chain line.
   - Grid: **2 columns on a phone** (a change from today's single column, so 1,619 subjects aren't an
     endless scroll), 3 at `lg`. Long names and chains must wrap inside the card
     (`overflow-wrap: anywhere`), never widen it. At phone width a card is about 160px wide, so
     "Provence-Alpes-Côte d'Azur" will break across lines.
5. **Pagination**: as now, 120 per page.

### Search

- **Scope: all three types**, not just the current tab. Ordering is match quality first (name
  equals the query, then name starts with it, then a word in the name starts with it, then name
  contains it, then alias-only), with the current tab's type as the tiebreaker within a quality,
  then ranked count. Ruling made during the build: "current type first" alone put Europe above War
  for "war", because past merges left junk alternative names on Europe ("World War I Europe"). A
  name match must beat an alias-only one. Each
  result card names its type ("Subject") in addition to its parent chain. The reason: genre and
  subject overlap in readers' minds (there is a "Political" genre and a "Politics" subject), and a
  reader looking for "War" shouldn't have to guess which tab it lives on. Results use the same
  cards, counts and links as the grid.
- **Matches** name or `alternative_names`, case-insensitive substring, as `CategorySearchQuery` does
  ("Calcutta" finds Kolkata).
- **Same gate as the grid.** It shows only what the grid would show: the same ranked-count join and
  the same per-type minimum, with ranked counts displayed. The simplest faithful build is
  `Books::BrowseQuery`'s ranked scope plus a name/alias condition, across types.
- **Results are capped** at a sensible number (60 or so), with a short "no matches" state. There is
  no pagination for results.
- **Endpoint:** uncached (`prevent_caching`), a GET with `?q=`, e.g. `/categories/search?q=war`.
  Search terms are unbounded and not worth caching, so a query string is right here. The
  path-segment rule is about the cacheable browse views. The endpoint renders results only; it is
  `noindex`.
- **Interaction:**
  - typing (debounced, at least 2 characters) swaps the card grid and pagination for the results;
  - clearing the box restores the grid as it was.
  - Build it on Turbo: a GET form whose results load into a frame, with a small Stimulus controller
    that submits as you type, following the filter modal's live search.
- **Without JavaScript,** submitting the form shows a full results page.
- **Turbo trap:** the results frame contains links to other pages, so it needs `target: "_top"` (see
  "Turbo Frames trap links" in `AGENTS.md`). The form that fills it needs
  `data: {turbo_frame: <id>}`, because `_top` on the frame releases forms too.

### `/countries` ("Book Origins")

It shares `BrowseToolbarComponent` and `BrowseCardComponent`. It picks up the new sort dropdown, so
the two pages look alike. It gets **no** tabs, search, URL change or chain line.

## 9. Constraints

- **Edge caching:**
  - every browse view stays `cache_for_index_page` (6 h public, no session cookie);
  - the page's HTML must be identical for every visitor;
  - the search endpoint is never cached.
- **No N+1 on the parent chain.** Up to 120 cards per page, each needing up to 5 ancestors. Load the
  ancestors for the whole page in one or two queries: a recursive CTE over the page's ids, or one
  query per level. Never call `category.ancestors` per card. A query-count test should pin this.
- **daisyUI 5 / Tailwind 4 only.** Check every class against
  `docs/external-libraries/daisyui-llms.txt`. The removed-class lint test must stay green.
- **Tests:**
  - routing (new grammar, constraints, and every `/genres` redirect shape in one hop);
  - controller (status, canonical, noindex, cache headers, search gating and ordering);
  - query (search uses ranked counts and the minimum, alias matching, cross-type ordering);
  - component (tabs, dropdown links, chain rendering);
  - a Playwright spec: rewrite `e2e/tests/books/browse.spec.ts` for `/categories`, and add search.
- **Existing tests** that hardcode `/genres` move to `/categories` or become redirect assertions:
  `browse_controller_test.rb`, `books_browse_routing_test.rb`, `browse_path_test.rb`,
  `browse_toolbar_component_test.rb`, `filter_pane_component_test.rb`, `footer_component_test.rb`.
  `legacy_categories_controller_test.rb` should still pass untouched.

## 10. Left to the builder

- Controller shape: keep `Books::BrowseController#genres` (renamed) or split out a `CategoriesController`.
- How the `/genres` redirects are expressed: route-level `redirect(...)` blocks or a small
  controller action. The one-hop requirement and the query-form case decide it.
- Where the chain query lives (a method on `BrowseQuery`, or a small query object) and its exact SQL.
- The search result cap, debounce timing, and empty-state copy.
- Whether the count label reads "4,858 books" (as now) or "4,858 ranked books".
- Exact responsive breakpoints for the toolbar.
- A feature doc update. `docs/features/books-categories.md` describes the browse threshold and the
  slug resolver, so add the page there.
