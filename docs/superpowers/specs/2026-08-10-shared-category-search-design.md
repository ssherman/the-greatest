# Shared Category Search — Design

**Date:** 2026-08-10
**Status:** Approved, not yet implemented

Unify the two independent category-search implementations behind one query object every domain can
use, give the public side the type label the admin side has always had, and add optional filtering
by `category_type` for callers that want a single type.

---

## 1. Why

Two implementations of "search categories by name" exist, neither aware of the other.

| | `Admin::CategoriesBaseController#search` | `Books::CategorySearchQuery` |
|---|---|---|
| Reachable by | books / games / music admin | the public books filter modal |
| Shows the category's type | **yes** — `"Name (Genre)"` | **no** |
| Filters by `category_type` | no | no |
| Orders by | `name` | `item_count DESC, name` |
| Limit | 20 | 10 |
| Returns | JSON `{value:, text:}` | an ActiveRecord array |

The admin one already does the thing worth keeping — it labels each result with its type — and it
is already cross-domain, resolving `model_class` per domain. It is also behind admin auth, so the
public side cannot reach it, which is why the second one exists.

### The gap: an unlabelled search across three types

The filter modal's Category axis deliberately spans genres, subjects and settings. That is not an
oversight and must not be "fixed": the placeholder reads *"Search genres, subjects, settings"*, and
`e2e/tests/books/filters.spec.ts` asserts that searching `new york` — a setting — returns rows. The
axis boundary that pane enforces is Category vs Origin, which its `peruvian` test pins.

What the pane does *not* do is say which type each result is. Active books categories, measured
2026-08-10:

| `category_type` | count |
|---|---|
| genre | 199 |
| location | 15,706 |
| subject | 36,852 |

So searching `americ` returns twelve rows spanning all three types, indistinguishable from one
another:

```
American History               subject    1948
Americana                      genre      1634
American                       location    705
African American History       subject     248
African American               subject     240
The United States of America   subject     191
Native American                subject     121
American dream                 subject     110
American Culture               subject      99
Latin America                  location     94
Native Americans               subject      92
Latin American                 location     69
```

Every one of those is a legitimate filter. The user simply cannot tell that picking the second
narrows to a genre while picking the third narrows to a setting — and the admin UI, searching the
same table, has shown exactly that distinction all along.

**Browse and search differ, deliberately.** `FilterFacetsQuery#genre_facet` scopes the browsable
list to `category_type: genre`, because browsing 52,757 rows is only useful narrowed to the 199
genres, while searching by name benefits from the whole space. This design does not disturb that.

---

## 2. Scope

**In scope:** one shared `CategorySearchQuery` with optional `category_type` filtering; a shared
label for `"Name (Type)"`; the admin controller delegating to both; the filter modal's rows
rendering the type; deleting `Books::CategorySearchQuery`.

**Out of scope:**

- **Changing which categories the filter modal returns.** The Category axis stays all-types. Only
  the label is added.
- **The multi-select autocomplete widget.** Increment 6 of the saved-searches spec needs six
  multi-select category pickers and the existing `AutocompleteComponent` is single-select, so the
  widget has to be built — but it is built there, with its first real consumer, rather than here
  with none.
- **Converting the filter modal onto that widget.** The pane UI stays as it is. Changing what it
  renders is a separate piece of work with regression risk against a page in production.
- **A public JSON category endpoint.** Nothing needs one until increment 6's form does. It is one
  controller action on top of the query this design delivers.
- **Languages and countries.** Not categories — `Language` and `Books::Country` are their own
  tables with no `category_type`. Increment 6 adds their endpoints.

---

## 3. The query

```ruby
CategorySearchQuery.call("americ", scope: Books::Category, limit: 10)
CategorySearchQuery.call("americ", scope: Books::Category, types: [:genre])
```

Top-level and domain-agnostic: it takes the scope to search rather than deriving it, so an admin
controller passes its `model_class`, the filter modal passes `Books::Category`, and a future games
caller passes `Games::Category` without this class learning about domains.

**`types:` is optional and defaults to unscoped**, which is load-bearing rather than a
convenience. Both callers that exist today need every type — the admin add-category modal because
a book legitimately gets tagged with a subject or a setting, and the filter modal because its
Category axis is defined as all three. A design that made filtering mandatory would break both.

**`types:` has no caller in this change.** It is built because it was explicitly asked for and
because the underlying column makes it a two-line addition, not because a consumer is waiting.
Increment 6 may or may not want its saved-search genre picker scoped; legacy's
`included_category_ids` spans all types, so the likely answer is no.

**Ordering is `item_count DESC, name ASC`** — the public query's ordering, not the admin's `name`.
On a 52,757-row table, alphabetical ordering surfaces whichever match sorts first; `item_count`
surfaces the one a user is overwhelmingly likely to mean. A deliberate change in admin behaviour.

**Blank query returns `[]`**, preserving the public behaviour. Admin today returns the first 20 by
name for a blank query; that difference disappears, which is correct — an autocomplete with an
empty box should offer nothing rather than an arbitrary alphabetical slice.

**Soft-deleted categories stay excluded** (`active`), as both implementations already do.

## 4. The label

One shared way to render `"Americana (Genre)"`, with `"Unknown"` for a `nil` `category_type`,
exactly as the admin controller does inline today. It exists so the string is defined once: the
admin JSON, the filter-modal rows and increment 6's picker all render the same thing.

`category_type` is an enum, so `titleize` on the key is the implementation. The `nil` case is
reachable — `db/schema.rb:224` has `default: 0` with no `null: false` — and both the current admin
guard and this design keep it.

---

## 5. What changes at each call site

**`Admin::CategoriesBaseController#search`** delegates to the query and the label. Output shape is
unchanged (`{value:, text:}`), so `AutocompleteComponent` and every admin category picker keep
working untouched. It gains an optional `types` param it does not yet pass. Two behaviours change
deliberately: ordering becomes `item_count DESC` (§3), and a blank query returns `[]`.

**`Books::FiltersController#render_pane_results`** keeps calling with no `types:`, so the rows it
returns are unchanged. The rows partial renders the type beside the name — the visible change.

**`Books::CategorySearchQuery` is deleted.** After the change above it has no callers, and leaving
it preserves the second way of doing this.

The country half of `render_pane_results` is untouched: `Books::CountrySearchQuery` searches a
different table with no type concept.

---

## 6. Testing

**Query unit tests.** Unscoped returns every type; `types: [:genre]` returns only genres;
`types: [:genre, :location]` returns both; ordering puts the higher `item_count` match first; a
blank query returns `[]`; a soft-deleted category never appears; `limit` is honoured; the `scope:`
argument keeps another domain's categories out.

The type-filtering tests need fixture categories of different types sharing a name prefix.
`test/fixtures/categories.yml` today has no such overlap — `books_fiction_genre`,
`books_politics_subject` and `books_france_location` share no prefix — so the fixtures must gain
one, or the tests pass without ever exercising the filter.

**Label unit tests**, including the `nil` `category_type` → `"Unknown"` case.

**Admin controller tests** across two domains: the JSON shape is unchanged, the default is still
unscoped — a book must still be taggable with a subject — and the two deliberate behaviour changes
hold.

**Filter modal.** The existing Playwright coverage in `books/filters.spec.ts` must keep passing
unchanged; in particular the `new york` test, which proves settings still come back from the
Category axis. One assertion is added: a search result row displays its type.

---

## 7. Landmines

- **The Category axis spanning genres, subjects and settings is deliberate.** The placeholder says
  so and two Playwright tests pin it. Anyone "fixing" that search to return only genres will break
  them. Browse is genre-only and search is all-types, on purpose (§1).
- **`types:` must default to unscoped.** Both existing callers need every type; making the filter
  mandatory breaks tagging and the filter modal at once.
- **`Category` is STI *and* has a `category_type` enum**, and they are different axes. `type` is
  the domain (`Books::Category`); `category_type` is genre/location/subject/theme/game_mode/
  player_perspective. Scoping the wrong one silently returns another domain's categories.
- **Only 199 of 52,757 active books categories are genres.** A category search that does not scope
  by type is, in practice, mostly a subject search — which is why the label matters.
- **`friendly_id` is scoped by `type`, not `category_type`**, so name collisions across
  `category_type` within a domain are real and expected — "American" is a location category *and*
  (separately) a `Books::Country`. The label is what disambiguates them for a user.
- **The admin JSON shape is a contract** with `AutocompleteComponent`'s `value_key`/`display_key`
  defaults. Changing `{value:, text:}` breaks every admin category picker at once.
