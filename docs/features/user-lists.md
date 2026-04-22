# User Lists

## Overview
User Lists are personal, ordered collections that logged-in users use to organize items they care about across the four media domains (music albums, music songs, games, movies). Each user automatically receives a predefined set of default lists (e.g. "Favorite Albums", "Games I've Played") on signup and can create an unlimited number of additional custom lists.

This feature corresponds to the `user-lists-01` spec (data model and core backend). UI, controller endpoints, and cached-page integration are delivered in a follow-up spec.

## Architecture

### Class Hierarchy (STI)
```
UserList                                 (base class, abstract)
├── Music::Albums::UserList              list_type: favorites, listened, want_to_listen, custom
├── Music::Songs::UserList               list_type: favorites, custom
├── Games::UserList                      list_type: favorites, played, beaten, want_to_play, currently_playing, custom
└── Movies::UserList                     list_type: favorites, watched, want_to_watch, custom

UserListItem                             (single class, polymorphic via `listable`)
```

`UserList` is a **separate STI hierarchy** from the editorial `List` class. They share no fields, no approval workflow, and no tables. `UserList` lives in `user_lists` and holds no editorial concerns (no wizard state, AI parsing, penalties, etc.).

### Scoping by Item Type
Each `UserList` subclass is bound to one `listable` item type via a `self.listable_class` class method. `UserListItem#listable_type_compatible_with_user_list` enforces at the model level that you can only add, for example, a `Music::Album` to a `Music::Albums::UserList`.

### List Types
Each subclass declares its own `enum :list_type` with a subclass-specific set of keys and a shared `custom` key. Because each subclass scopes its own queries (e.g. `Music::Albums::UserList.favorites`), the fact that the underlying integer values collide across STI subclasses is harmless in practice.

- **Default lists** are the non-`custom` list_types. They are created automatically on user signup (see Default-List Bootstrap below).
- **Custom lists** are the only list type users can create through the API. They're for freeform grouping.

### Default-List Bootstrap
On `User.create`, an `after_create :create_default_user_lists` callback iterates over `UserList::DEFAULT_SUBCLASSES` and calls `find_or_create_by!` for every subclass's `default_list_types`. The result is **12 default lists** per new user:

| Subclass                   | Count | Types |
|----------------------------|-------|-------|
| `Music::Albums::UserList`  | 3     | favorites, listened, want_to_listen |
| `Music::Songs::UserList`   | 1     | favorites |
| `Games::UserList`          | 5     | favorites, played, beaten, want_to_play, currently_playing |
| `Movies::UserList`         | 3     | favorites, watched, want_to_watch |

Because fixture loading bypasses ActiveRecord callbacks, fixture users do NOT receive default lists automatically. Tests that rely on the callback must build users via `User.create!`.

### Position Management on `UserListItem`
- `before_create :set_position` — appends new items at the end (`max(position) + 1`).
- `after_destroy_commit :shift_positions_up` — decrements position for all siblings with a higher position, in a single SQL UPDATE, so positions stay contiguous.
- `scope :ordered, -> { order(:position) }` — explicit ordering scope; no `default_scope`.

Reordering is implemented via `UserList#reorder_items!(ordered_listable_ids)`, which requires the caller to pass **exactly** the current set of listable IDs (no additions, no removals) and applies the new positions inside a transaction.

### Uniqueness Constraints
- **One copy of a given item per list** — DB-level `UNIQUE(user_list_id, listable_type, listable_id)` plus a model-level `validates :listable_id, uniqueness:`.
- **One default list per (user, type)** — enforced at the model level only (`one_default_per_type_per_user`). There is no DB partial unique index: default lists are only ever created through the idempotent signup callback, so the model-level check is sufficient and keeps the schema simple.

### Public vs Private
Each `UserList` has a `public` boolean (default false). Individual list visibility is per-list. Public-list queries use the `public_lists` scope, backed by a `WHERE public = true` partial index.

## Key Files

| File | Purpose |
|------|---------|
| `db/migrate/20260422002612_create_user_lists_and_user_list_items.rb` | Schema |
| `app/models/user_list.rb` | Base STI class, shared behavior, `DEFAULT_SUBCLASSES`, abstract class methods |
| `app/models/music/albums/user_list.rb` | Music albums subclass |
| `app/models/music/songs/user_list.rb` | Music songs subclass |
| `app/models/games/user_list.rb` | Games subclass |
| `app/models/movies/user_list.rb` | Movies subclass |
| `app/models/user_list_item.rb` | Polymorphic join with position callbacks + type-compatibility validation |
| `app/models/user.rb` | `has_many :user_lists`, `after_create :create_default_user_lists`, `default_user_list_for` |
| `app/models/music/album.rb`, `music/song.rb`, `games/game.rb`, `movies/movie.rb` | Each declares `has_many :user_list_items, as: :listable` |

## Usage Examples

```ruby
# Every user gets defaults automatically on signup
user = User.create!(email: "new@example.com")
user.user_lists.count                         # => 12
user.default_user_list_for(Games::UserList, :favorites)
# => #<Games::UserList name: "Favorite Games" ...>

# Adding an item appends at the next position
fav_games = user.default_user_list_for(Games::UserList, :favorites)
fav_games.user_list_items.create!(listable: Games::Game.first)

# Type-compatibility is enforced
fav_games.user_list_items.create!(listable: Music::Album.first)
# => raises ActiveRecord::RecordInvalid: Listable type Music::Album is not compatible...

# Reordering
list = user.default_user_list_for(Music::Albums::UserList, :favorites)
list.reorder_items!([album3.id, album1.id, album2.id])

# Public lists
list.update!(public: true)
UserList.public_lists.where(user: user)
```

## What's Not In This Spec
- JSON CRUD endpoints, UI, "Add to list" widgets, Stimulus controllers, ViewComponents — all deferred to `user-lists-02`.
- Dynamic community lists aggregated from user favorites — deferred to `user-lists-03`.
- `Books::UserList` — books item model doesn't exist yet; will be added when the books domain lands.

## Related Documentation
- `docs/specs/user-lists-01-data-model.md` — originating spec
- `docs/features/domain-scoped-authorization.md` — admin/editor role model (admin bypass is relevant here)
