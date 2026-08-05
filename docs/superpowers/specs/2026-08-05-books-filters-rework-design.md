# Books Filters Rework — Design

**Date:** 2026-08-05
**Status:** Approved, not yet implemented
**Supersedes:** `docs/superpowers/plans/2026-08-04-books-filters-category-typeahead.md`
**Builds on:** `docs/superpowers/specs/2026-08-03-books-filters-design.md` (increments 1–4 merged at `01d52540`)

Restructures the books filter modal from one flat 345-row panel into a two-level
drill-down with per-axis server-side search, adds `/genres` and `/countries` browse
pages, and replaces the legacy site's crawl-trap sidebar with an explicit crawl policy.

---

## 1. Problem

Increment 4 of the books-filters design shipped a single modal holding every facet
value at once. Three things are wrong with it.

**It is too large for a phone.** Commit `25b7c560` raised
`Books::FilterFacetsQuery::DEFAULT_LIMIT` to 500 so the client-side search box would
cover the whole taxonomy rather than a top-36 slice. The consequence is that the modal
now renders **166 genre checkboxes + 179 country checkboxes = 345 rows**, in two 224px
scroll wells, above two year inputs and an action row — roughly 700px of content, which
fills a current iPhone viewport and is worse on an older one.

**The search box is not scoped to an axis.** `books--filter-search` toggles `hidden` on
every option target by substring match, and the placeholder reads *"Filter genres and
countries."* Typing `france` hides every genre. Legacy never did this — its
`CategoryFilterComponent` ships `placeholder="Search for Genres"` against a
genre-scoped endpoint.

**Two axes cannot be represented at all.** Subjects (36,852) and locations (15,706) are
valid filter values in the URL grammar and arrive from book detail page links, but the
modal cannot render them, so they survive an Apply round-trip as hidden inputs. The
superseded typeahead plan identified the trap this creates: the moment they become
selectable they are also unselectable, because a hidden input has no affordance.

The through-line is that the modal is a port of the legacy **desktop sidebar** — a
surface designed for 1100px of vertical real estate — into a phone-sized box.

## 2. What legacy actually does

The live site does not use a single modal. `BooksFilterByComponent` renders a
`Filter by:` bar with three buttons, each opening a single-axis modal:

```
Filter by:  [Genres]  [Dates]  [Countries]
                ↓
┌─ Filter by Genre ─────────────────┐
│  ✕ Remove "Novels" Filter         │   selected values hoisted to the top
│  [ Search for Genres… ]           │   per-axis server autocomplete
│  Fiction (9,881)   Fantasy (2,204)│   ~12 popular values, 2 columns, with counts
│  Classics (1,904)  Sci-Fi (1,762) │
│  View all genres →                │   escape hatch to /genres
└───────────────────────────────────┘
```

Four behaviours carry forward into this design:

1. **One axis visible at a time.**
2. **Search is scoped to that axis** and runs on the server.
3. **Categories are a single UI axis.** Legacy browses genres but its autocomplete
   searches every active category type. This is why legacy has three buttons rather
   than five.
4. **A short popular list plus a link out to a full browse page**, not the whole
   taxonomy inline.

Legacy also caps selections at **6 genres and 10 countries**, and applies immediately —
every option is a link, there is no staging.

## 3. Research

Baymard and NN/g converge on four principles. The current modal violates three.

| Principle | Current state |
|---|---|
| Filters get their own layer on mobile (full-screen or bottom sheet), not a cramped box | `modal-box max-w-xl`, no `modal-bottom` |
| Group filters; collapse or defer all but the primary group | 345 values, all expanded |
| **Search within a facet** when its list is long — Lowe's per-facet search is the cited exemplar | one global search across both axes |
| Explicit Apply on mobile rather than live re-filtering | already correct |

NN/g's tray pattern assumes facets small enough to browse and does not address facets
with hundreds of values; Baymard's answer for long lists is search-within-facet. Neither
recommends a flat list at this scale.

Sources: [Baymard, *What Is an Ecommerce Filter? UI Best Practices*](https://baymard.com/learn/ecommerce-filter-ui) ·
[NN/g, *Mobile Faceted Search with a Tray*](https://www.nngroup.com/articles/mobile-faceted-search/)

---

## 4. Structure

One `<dialog>`, two levels, three axes. `modal-bottom sm:modal-middle` so it is a bottom
sheet on phones and a centred dialog on desktop, with a capped height; only the pane body
scrolls and `Clear` / `Apply` stay pinned.

```
LEVEL 1 (no query at all)                LEVEL 2 — Category
┌─ Filters ─────────────────── ✕ ┐   ┌─ ‹ Category ──────────────── ✕ ┐
│                                │   │ [ Search genres, subjects…   ] │
│ Category   Novels, Politics  › │   │ ─ results ──────────────────── │
│ Origin              French   › │ → │  ☐ Politics          Subject   │
│ Published        Since 1900  › │   │  ☐ Paris             Setting   │
│                                │   │ ─ popular genres ───────────── │
│                                │   │  ☑ Novels           (12,043)   │
│ [Clear]              [Apply]   │   │  ☐ Fiction           (9,881)   │
└────────────────────────────────┘   │  … 24 shown                    │
                                     │  Browse all genres →           │
                                     │ [Clear]              [Apply]   │
                                     └────────────────────────────────┘
```

Level 1 runs **zero queries** — it summarises filters the page already resolved. Opening
the modal is instant. A facet query runs only on entering a pane, and only for that axis.
Today, opening the modal eagerly runs both facet queries.

### Axes and labels

| Row | Label | Hint | Backing |
|---|---|---|---|
| 1 | **Category** | "Genre, subject, or setting" | `Books::Category`, all three types |
| 2 | **Origin** | "The book's national tradition — *Lolita* is American, though Nabokov was Russian" | `Books::Country` |
| 3 | **Published** | — | `first_published_year` range |

The Category pane **browses genres** and **searches all three types**, each search result
carrying a type badge (`Subject`, `Setting`). This is legacy's behaviour plus the badge.

Naming is the fix for a genuine ambiguity: a book's *origin* (`Books::Country`, rendered
`The Greatest French Novels`) and its *setting* (`location` category, rendered `Set in
France`) are different axes that legacy labels "Countries" and "Locations" — and legacy's
own URL, `/written-by/:country/authors`, frames origin as author nationality, which is
wrong. *Lolita* is an American novel written by a Russian. "Origin" and "Setting" do not
collide the way "Country" and "Location" do, and "Setting" matches what
`Books::FilterTitle` already emits.

**This is display copy only. No URL changes.** The filter grammar is the indexed product.

---

## 5. State model

Drill-down means panes are shown and hidden and search results are replaced. Staged
selections must survive both. The rule:

> **Panes are CSS-toggled, never replaced. Search results are ephemeral. Checking a
> search result hoists that row out of the results container into the pane's persistent
> Selected list.**

Concretely:

- Each pane is a `<turbo-frame>` whose `src` Stimulus assigns on **first visit only**.
  After that, navigation between level 1 and a pane is pure CSS, so the browse list and
  every checkbox in it persist untouched.
- Searching replaces only the pane's `results` sub-container.
- Checking a result **moves that `<label>`, input and all, into the pane's Selected
  list**, which nothing clears.
- Level 1's summary text is updated by the same controller on change.

Everything lives inside one `<form method="get" action="/filters"
data-turbo-frame="_top">`, so **Apply remains a plain form submit** and
`Books::FilterPath` remains the only place the URL grammar exists. There is no JS
reimplementation of path building to drift.

This also removes the hidden-input trap: a staged subject or setting is a visible checked
row and can be unchecked.

**Why hoisting rather than re-rendering.** The alternative is to thread the staged slug
set through every pane and search request and re-render rows server-side with the right
`checked` state. That is less JavaScript but more round trips, and it makes every request
stateful. Hoisting keeps requests stateless and confines the mutation to one direction —
ephemeral container → persistent list — which is testable in Playwright by checking a
result, searching again, and asserting the row survived.

---

## 6. Endpoints, queries, components

### Routes

| Route | Purpose |
|---|---|
| `GET /filters` | unchanged — validates, 303s to the canonical path |
| `GET /filters/categories` | Category pane body; with `?q=` returns search rows instead |
| `GET /filters/countries` | Origin pane body; same |
| ~~`GET /filters/options`~~ | **deleted**, with its action and component |
| `GET /genres` | browse page (§7) |
| `GET /countries` | browse page (§7) |

The Published pane is two number inputs and renders inline — no endpoint.

### Queries

- **`Books::FilterFacetsQuery`** — split so each axis is independently callable, and each
  pane fetch runs one query rather than two. `DEFAULT_LIMIT` **500 → 24**. The asymmetry
  documented in the existing class (genres keep the category filter applied and report the
  intersection; countries drop the country filter and report alternatives) is preserved
  verbatim. **`.call` keeps returning the two-axis `Result`** so the increment-4
  `FilterFacetsComponent` still renders until increment 2 deletes it; the per-axis entry
  points are added alongside it, not in place of it.
- **`Books::CategorySearchQuery`** — salvaged from the superseded plan unchanged. All
  active types, `item_count desc, name asc`, limit 10, returning `category_type` for the
  badge. Blank query returns `[]`. Legacy's trailing `.sorted_by_name` re-sorts the whole
  relation before limiting and so discards the popularity ordering; that is a legacy bug
  and is not ported.
- **`Books::CountrySearchQuery`** — new, same shape, over `Books::Country.filterable`
  ordered by `book_count desc, name asc`.
- **`Books::FilterParams`** — gains the caps (§8). Otherwise untouched.
- **`Books::FilterPath`**, **`Books::FilterTitle`**, **`Books::RankedBooksQuery`** —
  untouched. Their existing tests are the regression guard.

### Components

- `Books::FilterBarComponent` — **unchanged.** Button plus crawlable chip-removal links.
- `Books::FilterModalComponent` — **rewritten.** Dialog shell, the form, level 1, three
  pane shells.
- `Books::CategoryPaneComponent`, `Books::CountryPaneComponent`,
  `Books::YearPaneComponent` — new.
- `Books::FilterOptionRowsComponent` — new. The shared checkbox-row renderer, used by both
  the panes and the search responses, so a row is defined once and the hoist mechanism has
  one shape to move.
- `Books::FilterFacetsComponent` — **deleted.**

### JavaScript

`books--filter` replaces `books--filter-search`. One controller, responsible for: pane
navigation, first-visit `src` assignment, debounced search (250 ms), hoist-on-check, and
level-1 summary text. Target ~100 lines.

---

## 7. Discovery: `/genres` and `/countries`

Dropping the desktop sidebar removes the site's internal-link surface for single-facet
pages, so replacing it is a dependency, not a follow-up.

- **`GET /genres`** — legacy's URL exactly. Type toggle (Genres / Settings / Subjects),
  sort by count or name, card grid, each card linking to `/the-greatest/:slug/books`.
- **`GET /countries`** — same shape, cards linking to
  `/the-greatest-books/written-by/:slug/authors`.

Both are page-cached, so they cost nothing per request. Both are linked from the books
footer so they are not orphaned.

**Legacy's `/genres` renders every active category unpaginated** — 36,852 rows for
subjects — which is part of why it is slow. The new pages are bounded: ordered by
`item_count desc` and paginated with pagy at the same page size the ranked index uses, so
the highest-value pages sit on page 1. Paging uses the existing `/page/:n` path form, per
the books pagination convention.

⚠️ Legacy also serves **`/genres/:id`** show pages. Those are out of scope: on the new
site a category's page *is* its filter URL, `/the-greatest/:slug/books`. `/genres/:id`
needs a 301 before cutover, alongside the other deferred legacy paths (`/women`,
`/western`, `/asia`, `/africa`, `/latin-america`, `/non-western`, `/condensed`,
`/global-canon`, `/that-start-with/:letter`).

---

## 8. Selection caps

**6 categories, 10 countries**, ported from legacy, enforced in `Books::FilterParams`.

Categories are ANDed as one subquery each, so the cap directly bounds query cost as well
as URL length. `FilterParams` already raises `ActiveRecord::RecordNotFound` on an unknown
slug and the controller already renders that as a 404; exceeding a cap uses the same seam
and the same failure mode, so there is one error path rather than two.

The modal disables further checkboxes on that axis once the cap is reached and explains
why, matching legacy's copy.

---

## 9. Crawl and index policy

The legacy sidebar puts ~35 genre links and ~50 country links on **every** page,
including every already-filtered page, which makes the crawl frontier combinatorial. That
is why the live site needs Cloudflare rules rejecting paths with more than two commas,
and why filter pages are rarely warm in cache: the link surface mints an unbounded set of
unique URLs, so nothing repeats often enough to stay cached. The sidebar is both the cost
and the reason the cost cannot be amortised.

Google's [faceted navigation guidance](https://developers.google.com/crawling/docs/faceted-navigation)
is direct: *"Oftentimes there's no good reason to allow crawling of filtered items, as it
consumes server resources."* It recommends robots.txt as the primary control, calls
`rel=canonical` *"generally less effective in the long term"*, and calls `nofollow`
impractical since every link must carry it. Its positive recommendation — allow crawling
of item pages plus a dedicated unfiltered listing page — is §7.

That guidance is written for e-commerce, where facet pages are near-duplicates. Here they
are not: "The Greatest French Novels of All Time" is a real destination with a unique
title and a unique result set, and the filter surface is the site's long-tail product. So
the policy splits the space rather than blocking all of it.

| Class | Shape | Treatment |
|---|---|---|
| **1 — frontier** | one category **or** one country, ± dates | Linked from `/genres`, `/countries`, book detail pages, chips. Indexable. |
| **2 — valuable, not a frontier** | one category **+** one country, ± dates | Indexable. Reachable and rankable, but nothing generates them combinatorially. |
| **3 — tail** | ≥2 categories or ≥2 countries | Not linked anywhere. robots.txt disallowed. `noindex` as insurance. |

Classes 1 and 2 keep the existing canonical behaviour unchanged: `<link rel="canonical">`
at the sorted-slug form, which `Books::FilterPath` already emits, and no canonical at all
on `/rc/` URLs (they are `noindex` per the books public-UI spec's D4).

The class predicate is a method on `Books::FilterPath` — it already owns the grammar and
already receives the resolved filter set, so no caller needs to learn the rule.
`Books::RankedItemsController` reads it to set `@no_index` alongside the existing `/rc/`
check.

**The URL grammar makes this expressible in two lines.** `Books::FilterPath` joins slugs
with commas, so a comma appears in the path if and only if a segment is multi-valued —
which is exactly the class-3 boundary:

```
Disallow: /the-greatest/*,*
Disallow: /*written-by/*,*
```

This retires the Cloudflare comma rule in favour of a directive Google and Bing honour,
and it is stricter than what is live today, since one comma is already the tail.

`noindex` on class 3 is inert while robots.txt blocks the fetch, and costs one predicate;
it earns its place if a class-3 URL is ever linked or crawled by an agent that ignores
robots.txt.

**What this gives up.** Internal link equity: the sidebar pushes links to ~85 facet pages
from every page, whereas `/genres` pushes to the same pages from one. That is weaker
per-page but focused, and it stops leaking equity into an unbounded junk space. Already
indexed URLs are not deindexed by removing links — they are crawled less often, which is
fine for content that changes only on recalculation.

**What it does not solve.** robots.txt does nothing about scrapers and AI crawlers that
ignore it, so Cloudflare remains the enforcement layer for those. The volume drops
sharply because discovery collapses, and the rule simplifies to "comma in path".

**The risk this creates.** `/genres` and `/countries` become the *sole* discovery surface
for the single-facet long tail. If they are thin, badly capped, or unlinked from the
footer, that tail loses its only entry point. Increment 3 is load-bearing.

---

## 10. Out of scope

- **Live result count on Apply** ("Show 1,234 results"). Baymard rates this high-impact
  and it is the first thing to add later, but it needs a fetch per toggle against a count
  query measured at 195 ms in the original design. Revisit once this lands.
- `/genres/:id` show pages (§7) and the other deferred legacy paths.
- Sort or filter controls inside panes beyond popularity ordering.
- Swapping the Postgres query engine for OpenSearch. `RankedBooksQuery`'s return type
  remains the contract.

---

## 11. Testing

**Unit**

- `Books::CategorySearchQuery` — blank query, case-insensitive substring, all three types
  returned, soft-deleted excluded, ordering by `item_count desc`, limit respected.
- `Books::CountrySearchQuery` — same, plus `unknown` excluded via `filterable`.
- `Books::FilterFacetsQuery` — per-axis callability, limit 24, and the existing own-axis
  exclusion and asymmetry assertions kept.
- `Books::FilterParams` — the two caps raise `RecordNotFound`; at-cap passes.
- The crawl-class predicate — class 1 / 2 / 3 assignment across the grammar, table-driven.
- `Books::FilterPath`, `Books::FilterTitle`, `Books::RankedBooksQuery` — **existing tests
  must pass untouched.**

**Component** — structural contracts only: input `name`/`value`/`checked`, row counts,
type badges present, `data-*` hooks. Never class names, layout, or copy.

**Controller / integration**

- `/filters/categories` and `/filters/countries` return 200 with and without `?q=`.
- `/filters` still 303s to the canonical path.
- `/filters/options` is gone (404).
- `/genres` and `/countries` return 200 and link to filter paths.
- `noindex` present on a class-3 URL, absent on class 1 and 2.
- `assert_queries_count` on `/genres` — a card grid rendering counts in a loop is exactly
  the shape that regresses into an N+1.

**E2E (Playwright)** — `e2e/tests/books/filters.spec.ts` is **rewritten**:

1. Open modal → level 1 shows three rows → enter Category → check a genre → back →
   enter Origin → check a country → Apply → assert URL and H1.
2. **The hoist regression:** enter Category → search a subject → check it → search
   something else → assert the checked subject row survived → Apply → reopen → assert it
   renders as a visible checked row that can be unchecked.
3. `/genres` → click a card → lands on the filter page.

---

## 12. Increments

Each is its own PR. Gate before each: `bin/rails test` + `bundle exec standardrb`.

| # | Scope | Verifiable by |
|---|---|---|
| 1 | Query layer: facet split + limit 24, `CategorySearchQuery`, `CountrySearchQuery`, `FilterParams` caps | unit tests |
| 2 | Modal rework: two endpoints, panes, `books--filter`, `FilterModalComponent`, at-cap checkbox disabling; delete `/filters/options`, its action, `FilterFacetsComponent`, `books--filter-search` | Playwright specs 1–2 |
| 3 | Discovery & crawl: `/genres`, `/countries`, footer links, robots.txt, `noindex` predicate | Playwright spec 3; robots assertions |

Increment 1 is not purely internal, despite touching no view. Two effects ship with it:
a URL carrying more than 6 categories or 10 countries starts returning 404, and the
existing modal shrinks from 345 rows to 48 because it reads `DEFAULT_LIMIT`. Both are
intended way-points toward increment 2, but the existing E2E spec asserts against the old
modal and will need its option-count expectations relaxed in increment 1 rather than
increment 2.

---

## 13. Landmines

- **`data-turbo-frame="_top"`** on the form. Without it the submit is captured by the
  enclosing frame instead of navigating. Carried over from the original design and still
  load-bearing.
- **Lazy turbo-frames do not fire while hidden.** `loading: :lazy` uses an
  IntersectionObserver, which does not fire inside a closed `<dialog>` or a
  `display: none` pane. Pane loading is an explicit first-visit `src` assignment, not
  `loading: :lazy`.
- **A hoisted row must carry its input.** Moving only the visible label and leaving the
  `<input>` behind silently drops the selection at Apply. Move the whole `<label>`.
- **`scope "(/rc/...)"` + `constraints:`** disables the optimized url helper and binds the
  positional arg to the rc segment. The rc prefix stays spelled out literally.
- **`ActiveRecord::FixtureSet.create_fixtures` truncates every table it names.** Read
  fixture YAML directly; never run it against development. The books data exists only in
  development.
- **`/genres` must be paginated or thresholded.** The subject taxonomy is 36,852 rows and
  legacy renders it unpaginated.
- The worktree shares the test database with the main checkout — do not run tests
  concurrently with another worktree.
