# Admin Domain Registry

## Overview

The admin is one set of controllers, views, and ViewComponents shared by every domain (music,
games, books, movies), switched by hostname. Two small registries make that possible without
per-domain `case` statements scattered across the codebase:

- **`Admin::DomainRouting`** (`app/lib/admin/domain_routing.rb`) answers *"which domain does this
  record belong to, and what's its admin URL?"*
- **`Admin::DomainNav`** (`app/lib/admin/domain_nav.rb`) answers *"what does this domain's admin
  chrome (layout, sidebar) look like?"*

Both are class-method-only namespaces (no instances) backed by plain Ruby hashes keyed by class
name or domain symbol. They are also the contract a new domain must satisfy to get a working
admin — a domain that's missing from one registry but present in the other produces a
half-wired admin (see "What a new domain must add" below), which is exactly the bug class this
pair was introduced to close (wrong-domain leaks: a games admin silently handed music's layout,
or redirected to music's homepage).

## Architecture

```
Admin::DomainRouting          Admin::DomainNav
  ENTITIES                      CONFIGS
  LISTS                           layout, title, logo
  RANKING_CONFIGURATIONS          section_label/icon, items
  NESTED_PARENTS                  categories_search_path
  PENALTIES                     FALLBACK_LAYOUT ("music/admin")
        │                              │
        └──────────────┬───────────────┘
                        ▼
        Admin::DomainScopedAuth#domain_with_admin_for
        (domain_for(record) must also have a DomainNav config,
         otherwise the domain is treated as "no admin" for auth)
```

They compose in exactly one place today: `Admin::DomainScopedAuth` (the concern behind
`Admin::RankedListsController`, `Admin::RankedItemsController`, and
`Admin::PenaltyApplicationsController`, which live outside any domain namespace) resolves a
ranking configuration's domain via `DomainRouting.domain_for`, then confirms via
`DomainNav.config_for` that the domain actually has an admin before granting access. A domain
registered only in `DomainRouting` (books, movies) is therefore still denied — see
`docs/features/domain-scoped-authorization.md`.

## Admin::DomainRouting

### Data tables

| Table | Keyed by | Value |
|---|---|---|
| `ENTITIES` | class name | `{domain:, path: ->(record), category_items_path: ->(record) or nil}` |
| `NESTED_PARENTS` | domain symbol | `{url param => class name}` — resolves the parent for controllers nested under a domain (images, category_items) |
| `LISTS` | List STI class name | `{domain:, listable_type:, item_label:, path: ->(list), autocomplete_path: ->()}` |
| `RANKING_CONFIGURATIONS` | RankingConfiguration STI class name | `{domain:, list_type:, ranked_item_includes:, path: ->(rc) or nil}` |
| `PENALTIES` | Penalty STI class name | itself (used only to resolve a `type` param string to a class) |

`RANKING_CONFIGURATIONS` registers all six `RankingConfiguration` subclasses, including
`Books::RankingConfiguration` and `Movies::RankingConfiguration` (with `path: nil`, since neither
domain has an admin yet). `LISTS`, by contrast, registers only three of the six `List`
subclasses — `Music::Albums::List`, `Music::Songs::List`, `Games::List` — because
`Books::List` and `Movies::List` never needed list-admin resolution until now. **This asymmetry
matters**: `Admin::DomainRouting.domain_for(Books::List.new)` returns `nil` today (no `LISTS`
entry), while `Admin::DomainRouting.domain_for(Books::RankingConfiguration.new)` returns `:books`
(it has a `RANKING_CONFIGURATIONS` entry, just with `path: nil`). Code that branches on whether
`domain_for` returned anything — rather than on whether a usable path came back — will treat the
two inconsistently for the same domain.

### Public API

```ruby
Admin::DomainRouting.domain_for(record_or_class)         # => :music / :games / :books / :movies / nil
Admin::DomainRouting.path_for(record)                    # => ENTITIES show path, or nil if unpersisted/unregistered
Admin::DomainRouting.category_items_path_for(record)     # => nil unless ENTITIES[...][:category_items_path] is set
Admin::DomainRouting.list_config(list)                   # => merged LISTS entry with path/autocomplete_path resolved, or nil
Admin::DomainRouting.ranking_configuration_config(rc)    # => merged RANKING_CONFIGURATIONS entry, or nil
Admin::DomainRouting.penalty_class(type_string)          # => a Penalty subclass, defaults to Global::Penalty
Admin::DomainRouting.parent_from_params(params, domain:) # => the record named by NESTED_PARENTS[domain], or nil
```

`list_config` and `ranking_configuration_config` always return `path: nil` for an unpersisted
record, and also return `path: nil` for a registered class whose table entry has `path: nil`
(books/movies ranking configurations today). Callers must handle the `nil` — see the two patterns
below.

## Admin::DomainNav

### Data tables

| Table | Keyed by | Value |
|---|---|---|
| `CONFIGS` | domain symbol | `{layout:, title:, section_label:, section_icon:, logo:, root_path: ->(), categories_search_path: ->(), items: [{label:, icon:, path: ->()}]}` |
| `FALLBACK_LAYOUT` | — | `"music/admin"`, used for any domain absent from `CONFIGS` |
| `ICONS` | icon symbol | SVG path data, shared by domain configs and their nav items |

Only `:music` and `:games` have `CONFIGS` entries. `:books` and `:movies` are deliberately absent
— there is no books or movies admin yet.

### Public API

```ruby
Admin::DomainNav.layout_for(domain)   # => CONFIGS[domain][:layout], or FALLBACK_LAYOUT
Admin::DomainNav.config_for(domain)   # => full config hash with every lambda called, or nil if the domain has no admin
```

`Admin::BaseController#admin_layout` calls `layout_for` to pick the layout per-request.
`app/views/admin/shared/_sidebar.html.erb` calls `config_for`: when it's `nil` (books, movies, or
any unmatched host — `ApplicationController#detect_current_domain` defaults unmatched hosts to
`:books`), the sidebar renders only the Global section (Penalties, Users), not a domain section.

## Usage examples

### Resolving a redirect / back-link path, with a fallback

```ruby
def redirect_path
  Admin::DomainRouting.ranking_configuration_config(@ranking_configuration)&.dig(:path) || music_root_path
end
```

### Rendering a link only when a path exists (no `link_to name, nil`)

```ruby
def ranked_list_link(list)
  path = Admin::DomainRouting.list_config(list)&.dig(:path)
  return list.name unless path

  link_to list.name, path, class: "link link-primary"
end
```

### Domain-scoped authorization restricted to domains with an admin

```ruby
def domain_with_admin_for(record)
  domain = Admin::DomainRouting.domain_for(record)
  domain.to_s if domain && Admin::DomainNav.config_for(domain)
end
```

### Domain-specific category search, with a fallback

```ruby
def search_url
  Admin::DomainNav.config_for(Admin::DomainRouting.domain_for(@item))&.dig(:categories_search_path) ||
    helpers.search_admin_categories_path
end
```

## What a new domain must add

Getting a domain a working admin means adding to *both* registries — one without the other
produces a half-wired admin:

1. **`Admin::DomainNav::CONFIGS[domain]`** — layout, title, logo, sidebar items, and
   `categories_search_path`. Without this, `DomainNav.config_for(domain)` stays `nil`: the sidebar
   shows no domain section, `admin_layout` falls back to `"music/admin"`, and — because
   `Admin::DomainScopedAuth#domain_with_admin_for` requires a `DomainNav` config — domain-role
   holders keep being denied on `Admin::RankedListsController` /`RankedItemsController` /
   `PenaltyApplicationsController` even after `DomainRouting` says a record belongs to their domain.
2. **`Admin::DomainRouting::RANKING_CONFIGURATIONS[type][:path]`** — currently `nil` for
   Books/Movies. Needed for the ranked-lists/ranked-items/penalty-applications redirect and
   back-link paths to point anywhere.
3. **`Admin::DomainRouting::LISTS[type]`** — not yet registered for Books::List / Movies::List.
   Needed for list-link resolution in the ranked-lists views, and would be a prerequisite for ever
   porting `Admin::ListItemsController` / `Admin::ListPenaltiesController` off their hand-rolled
   `list.type.split("::").first.downcase` domain check onto the registry.
4. **`Admin::DomainRouting::ENTITIES[type]`** — for each admin-manageable model, its show path and
   (if applicable) category-items path.
5. **`categories_search_path`** in the new `DomainNav::CONFIGS` entry —
   `Admin::AddCategoryModalComponent#search_url` reads it and otherwise falls back to the music
   category search. `test/lib/admin/domain_nav_test.rb` asserts every `CONFIGS` entry has one, so
   forgetting it fails a test instead of silently serving music's categories.

## Related Documentation

- `docs/features/domain-scoped-authorization.md` — the permission model these registries feed
- `docs/superpowers/specs/2026-07-13-books-admin-ui-design.md` — the in-progress design for adding
  books to both registries (a design spec, not a stable reference — read the code for current
  truth)
