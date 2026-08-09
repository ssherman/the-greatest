# Saved Searches

## Overview

A signed-in user can save a set of book filters (genres, languages, origins, book type/length,
publication-year range, ranked-only, hide-read, etc.), name it, optionally make it public, and
revisit it later at a stable URL. It is a **port** of the legacy books site's saved-search
feature: the stored criteria and the URLs it's reachable at have to keep behaving, because a
large batch of searches were migrated from the legacy database with their ids preserved
(increments 1–4, merged before this feature had any UI). Increment 5 is what turns it on —
`/searches` and `/searches/:id` are live for the first time.

The migrated count differs by database: **development** holds 4,391 searches across 1,152 users
(`SavedSearch.count` / `SavedSearch.distinct.count(:user_id)`), matching the design spec's legacy
figure exactly. **Production**, migrated 2026-08-09, holds 4,727 rows. Production's legacy books
corpus is larger than dev's in general, so dev counts never reproduce there — that gap is worth
knowing because it means an exact-count assertion that passes locally says nothing about
production.

Only books has saved searches today. The read surface (list, view, legacy-URL redirects) is
built; creating, editing, and deleting a search is deferred to a later increment.

## Architecture

Both actions start the same way — `SavedSearchesController` resolves
`domain_class = SavedSearch.subclass_for(Current.domain)`, 404ing if the current domain has no
subclass — and then diverge completely. `index` never touches OpenSearch, the query layer, or
`Books::CardComponent`; it's a plain Postgres list of the signed-in user's own searches:

```
GET /searches(/page/:page)
  |
  v
domain_class.owned_by(current_user).by_last_executed.by_created   # paged with pagy_path
  |
  v
index.html.erb — a DaisyUI `.card` per search (name, description, `#summary`), linking to `show`
```

`show` resolves one search, then runs its criteria through OpenSearch and hydrates one page from
Postgres:

```
GET /searches/:id(/page/:page)
  |
  v
domain_class.visible_to(current_user).find(params[:id])   # 404 unless owner or public
  |
  v
@search.criteria_object -> Books::SavedSearchCriteria     # typed reader over the raw criteria jsonb
  |
  v
Books::SavedSearchQuery.call(criteria:, owner: @search.user, page:, per_page:)
  |  owner's read-list ids, if hide_read is set
  v
Search::Books::Search::BookAdvanced   # OpenSearch: filters + sort + page + total, one call
  |
  v
Books::SavedSearchQuery hydrates the page   # a fixed, small number of Postgres queries
  |                                          # (base SELECT + preloads), not one per book
  v
show.html.erb -> Books::CardComponent grid
```

`SavedSearchesController` is a single global controller (no `DomainConstraint`), because
`Current.domain` — not the route — picks both the STI subclass and the layout
(`DomainLayout#resolve_layout`). A second domain plugs into the same controller; see
"Adding a domain" below.

## Key files

| File | Role |
|---|---|
| `app/controllers/saved_searches_controller.rb` | `index` (owner-only) and `show` (owner or, if public, anyone including anonymous) |
| `app/models/saved_search.rb` | STI base: `DOMAIN_SUBCLASSES`, `visible_to`/`owned_by` scopes, `criteria_object` memo |
| `app/models/books/saved_search.rb` | Books subclass: wires the criteria/query/filter-labels classes, `#summary` for the index card |
| `app/lib/books/saved_search_criteria.rb` | Typed readers over the raw `criteria` jsonb hash; no DB, no OpenSearch |
| `app/lib/books/saved_search_query.rb` | Orchestrates one execution: read-list lookup, `BookAdvanced` call, Postgres hydration |
| `app/lib/search/books/search/book_advanced.rb` | The OpenSearch bool query: every filter, the sort, the page window, the total |
| `app/lib/books/saved_search_filter_labels.rb` | Criteria -> display-ready groups for the show page's "Active filters" card |
| `app/policies/saved_search_policy.rb` | `show?` is `public? || owner?`; write actions gated but not yet wired to any controller action |
| `app/views/saved_searches/index.html.erb`, `show.html.erb` | Domain-independent: list of a user's searches; one search's results |
| `app/views/saved_searches/books/_active_filters.html.erb`, `_results.html.erb` | Books-specific partials the show view renders by `Current.domain` |
| `config/routes.rb` (`searches` block) | `/searches`, `/searches/:id`, paged forms, legacy `/v/:view_type/...` redirects |

None of `SavedSearchCriteria`, `SavedSearchQuery`, or `SavedSearchFilterLabels` has a shared base
class — each domain writes its own from scratch. Only the STI model, the controller, the routes,
and the shared concerns (`DomainLayout`, `PathBasedPagination`, `Cacheable`) are common code.

## Why OpenSearch owns filtering, paging, and the count

`BookAdvanced` is the *only* place a filter is applied. `Books::SavedSearchQuery` does no
filtering of its own — it just hydrates the page of ids OpenSearch already picked. This is
deliberate: OpenSearch sizes the page (`from`/`size`) and reports the total in the same response.
If a filter were applied afterward in Postgres — say, dropping a book that no longer matches —
it would remove rows from a page that was already sized and counted, producing a short page
alongside a total that overstates what's actually reachable.

The one thing `SavedSearchQuery` *does* do outside OpenSearch is resolve `hide_read`: it looks up
the search owner's `Books::UserList` (`list_type: :read`) and passes the book ids to
`BookAdvanced` as `excluded_book_ids`, which applies them as an OpenSearch `must_not`. Hydration
also silently drops any id OpenSearch returned that Postgres no longer has (a book deleted
without a reindex) — that page comes back short of `total`, which is considered better than
failing the request.

Hydration itself is not "one query" — the base `SELECT` plus its `.preload(book_authors:
:author, primary_image: {file_attachment: :blob})` are separate round trips. What matters, and
what's actually pinned by `saved_searches_controller_test.rb`'s `assert_queries_count(9)` on
`show`, is that the count is **fixed regardless of how many books land on the page** — it doesn't
grow per book, which is the N+1 that a grid of books rendering authors and a cover image per row
would otherwise invite.

## The URL surface

| URL | Behaviour |
|---|---|
| `GET /searches` | The current user's searches, ordered by last executed (nulls last), then newest created. Requires sign-in. |
| `GET /searches/page/:page` | Same, path-based paging. `page/1` 301s to the bare path. |
| `GET /searches/:id` | One search's results. Reachable by the owner always, or by anyone (including anonymous) if the search is `public`. Anything else 404s — never a 403 or a sign-in redirect, which would confirm the id exists. |
| `GET /searches/:id/page/:page` | Same, path-based paging; a legacy `?page=N` query param is also honoured (`Pagy::Method`). `page/1` 301s to the bare path. |
| `GET /v/grid/searches`, `/v/table/searches`, and their `/:id` and `/:id/page/:page` forms | Legacy view-switcher URLs. All 301 to the equivalent `/searches...` path — the page number carries through. Any `view_type` other than `grid`/`table` 404s. |

There is no view switcher (no grid/table toggle) — legacy's two views rendered the same book set,
so increment 5 dropped the second code path and made both legacy URLs redirect to one card grid
instead of resurrecting it.

Pages are per-user, so they are never cached (`prevent_caching`) and never indexed:
`public/robots.txt` disallows `/searches` outright, and the books `noindex, follow` default
(`@indexable` unset) applies too.

## Two rules a future change must not break

1. **`hide_read` filters against the search's owner, never the current viewer.** `SavedSearchQuery.call` is always given `owner: @search.user`, not `current_user`. This is what keeps a *public* search's results identical for every viewer — the "hide books I've read" the owner set stays about the owner, not about whoever happens to be looking.
2. **A criterion that's present but unresolvable must match nothing, not everything.** If a stored or submitted value doesn't parse (an unresolvable `book_type`, a category id that isn't an integer, ...), `BookAdvanced` adds `MATCH_NOTHING_CLAUSE` (`{terms: {category_ids: []}}`) rather than silently dropping the clause. Dropping it would turn a broken filter into an unfiltered search over the whole corpus — the opposite of what the user asked for.

## The 10,000-result ceiling

OpenSearch's `track_total_hits` is left at its default, which caps the reported total at 10,000
— a search broader than that reports exactly 10,000 and means "at least this many"
(`Result#capped?`). `BookAdvanced::MAX_RESULT_WINDOW` (10,000) is also OpenSearch's `from + size`
ceiling: a page beyond it is unreachable, so the query clamps `size` (and returns `size: 0` past
the window) rather than letting OpenSearch raise. `PER_PAGE` is fixed at 50 with no `?limit=`
override, which divides 10,000 exactly — the last reachable page (200) comes back full instead of
short. The show page renders a capped total as **"10,000+ results"** rather than the literal
number.

## Adding a domain

To add saved searches to a second domain (e.g. games), add:

1. A criteria class (`Games::SavedSearchCriteria`) — typed readers over that domain's raw `criteria` hash.
2. A query class (`Games::SavedSearchQuery`) — resolves `hide_read` against that domain's own read/played list and calls that domain's OpenSearch query class.
3. A filter-labels class (`Games::SavedSearchFilterLabels`) — criteria -> the show page's "Active filters" card.
4. Two view partials: `saved_searches/games/_active_filters.html.erb` and `saved_searches/games/_results.html.erb`.
5. One entry in `SavedSearch::DOMAIN_SUBCLASSES` (`"games" => "Games::SavedSearch"`), and a `Games::SavedSearch < ::SavedSearch` subclass that overrides all five hooks the base class declares abstract: `criteria_class`, `query_class`, `filter_labels_class`, `ranking_configuration_class`, and `excluded_list_type`. Skipping `ranking_configuration_class` — easy to do, since nothing in the controller or query path calls it today — still fails the base class's own contract: `SavedSearch.ranking_configuration_class` raises `NotImplementedError` on the base class, and `test/models/saved_search_test.rb` asserts that for every hook, this one included.

What's inherited for free: the route block, `SavedSearchesController#index`/`#show`,
`SavedSearch.visible_to`/`owned_by` scoping and the `criteria_object` memo, `SavedSearchPolicy`,
`DomainLayout` (picks the games layout from `Current.domain`), `PathBasedPagination`, and
`Cacheable`'s `prevent_caching`. Don't add a `Games::SavedSearchPolicy` — the controller
authorizes with `policy_class: SavedSearchPolicy` explicitly, so Pundit's default per-model
policy lookup never runs and a domain-specific policy class would simply never be called.

## Related documentation

- `docs/features/search.md` — the OpenSearch base classes (`Search::Base::Search`, query DSL
  builders) that `BookAdvanced` is built on.
- `docs/superpowers/specs/2026-08-08-books-saved-searches-design.md` — the full design spec,
  including the legacy migration and the reasoning behind each of the decisions above.
