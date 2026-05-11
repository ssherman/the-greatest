# User Lists — Part 2a: "Add to List" Widget on Item Pages

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-05-05
- **Started**: 2026-05-10
- **Completed**: 2026-05-10
- **Developer**: Shane Sherman (with Claude Code)

## Overview
Ship the "Add to List" widget on every page that has a single item context (cached index pages, item show pages — albums, songs, games; movies/books deferred until those domains have item pages). Authenticated users see a small icon strip on each card showing which default lists the item is already on, plus a button that opens a modal with a per-list checkbox view and an inline "create a new list" form. Anonymous clicks open the existing login modal first.

This spec **must** be CloudFlare-cache-safe: cached pages render an identical, anonymous-looking shell, and per-user state is loaded client-side via a single JSON endpoint + `localStorage`, then mutated through dedicated JSON endpoints.

**Non-goals (deferred to later specs):**
- `/my/lists` dashboard, per-list show page, drag-and-drop reorder, view modes, `completed_on` editing — all → `user-lists-02c`.
- Public-list discovery, "consumed badges" beyond the per-list-type icon strip — → `user-lists-02d` (or fold into 02c).
- Books domain — its item models don't exist yet.
- Movies cached-page integration — no movie cards/show pages exist yet. The data layer in this spec must work for movies (it shares everything), but no Movie card refactor is required.

## Context & Links
- Predecessor: `docs/specs/completed/user-lists-01-data-model.md` (data model + `reorder_items!` shipped)
- Feature doc: `docs/features/user-lists.md`
- Old-site reference (different stack but same UX intent): `docs/old_site/user-lists-feature.md` §"Global Bootstrapping Pattern"
- Cache mechanism (required reading): `web-app/app/controllers/concerns/cacheable.rb`
- Auth state on the client: `web-app/app/javascript/services/firebase_auth_service.js` and `web-app/app/javascript/controllers/authentication_controller.js`
- Login modal markup (the trigger target): `web-app/app/views/layouts/{music,games,movies}/application.html.erb` — `<dialog id="login_modal">`

### Pre-agreed design decisions (from discovery)
1. Cached item pages render an identical anonymous shell. All per-user state is client-side, hydrated from `localStorage` first, then refreshed from a JSON endpoint.
2. Routes are **global** (non-domain-constrained), like the existing `auth/sign_in` routes. Same controllers serve all four subdomains.
3. The state endpoint is **scoped to the current domain** via `Current.domain`. Per-domain `localStorage` buckets keep the payload small.
4. The state response is a **full dump** of the user's lists + memberships in the current domain. Math for an extreme power user (5,000 items) is ~60KB — well within the ~5–10MB per-origin localStorage quota in every modern browser.
5. Visual indicator on each item card is a **per-default-list-type icon strip**, declared per-subclass via `self.list_type_icons`. Custom lists collapse into a "+N" pill.
6. Anonymous click on the widget calls `login_modal.showModal()`. After successful sign-in the existing `reload_after_auth: true` flow reloads the page; the widget hydrates with the now-signed-in user's state.

## Interfaces & Contracts

### Domain Model (diffs only)

No migration. The schema is unchanged from Part 1.

**`UserListItem` — add user touch**

Add to `web-app/app/models/user_list_item.rb`:

```ruby
# reference only — touches user.updated_at so /user_list_state can return a monotonic version
after_commit :touch_user, on: [:create, :update, :destroy]

private

def touch_user
  user&.touch
end
```

**`UserList` — add user touch**

Add to `web-app/app/models/user_list.rb`:

```ruby
# reference only — bump version when a list is created/renamed/destroyed
after_commit :touch_user, on: [:create, :update, :destroy]

private

def touch_user
  user&.touch
end
```

**Each STI subclass — declare `list_type_icons`**

Add a class method that maps each `list_type` to a symbolic icon name. The base class declares the abstract method and a default of `{}`.

```ruby
# reference only — values are Lucide icon names (kebab-case strings)
class Music::Albums::UserList < UserList
  def self.list_type_icons
    {favorites: "heart", listened: "headphones", want_to_listen: "bookmark"}
  end
end

class Music::Songs::UserList < UserList
  def self.list_type_icons
    {favorites: "heart"}
  end
end

class Games::UserList < UserList
  def self.list_type_icons
    {favorites: "heart", played: "check", beaten: "trophy",
     currently_playing: "gamepad-2", want_to_play: "bookmark"}
  end
end

class Movies::UserList < UserList
  def self.list_type_icons
    {favorites: "heart", watched: "eye", want_to_watch: "bookmark"}
  end
end
```

`:custom` is **never** in the icon map — custom lists collapse into a "+N" pill on the card.

When `Books::UserList` lands, it adds its own `list_type_icons` (e.g. `{favorites: "heart", read: "book-check", reading: "book-open", want_to_read: "bookmark"}`) and the widget lights up automatically.

**Icon names are Lucide names verbatim.** They're rendered server-side by the `rails_icons` gem; the same string is also emitted as a JSON value in `/user_list_state` so the JS controller can render the matching icon client-side. Pick names that exist in Lucide's set (https://lucide.dev/icons/).

### Endpoints

All routes go in `web-app/config/routes.rb` **outside** any `DomainConstraint` block, alongside `auth/sign_in`. `Current.domain` is set by the existing `before_action :set_current_domain` in `ApplicationController` based on request host.

| Verb | Path | Controller#Action | Purpose | Auth |
|------|------|------|------|------|
| GET    | `/user_list_state`                       | `user_list_state#show`     | Bulk hydration JSON for current user, current domain | signed-in |
| POST   | `/user_lists`                            | `user_lists#create`        | Create custom list; optionally add an item atomically | signed-in |
| POST   | `/user_lists/:user_list_id/items`        | `user_list_items#create`   | Add an item to a list | owner |
| DELETE | `/user_lists/:user_list_id/items/:id`    | `user_list_items#destroy`  | Remove an item from a list | owner |

> Source of truth: `web-app/config/routes.rb`. Add these routes near the existing `auth/sign_*` lines.

**CSRF**: standard Rails `<meta name="csrf-token">` flow. Stimulus controllers read the token via `document.querySelector('meta[name="csrf-token"]')?.getAttribute('content')` (matching the existing `authentication_controller.js` pattern). Do **not** `skip_forgery_protection`.

**Caching**: every endpoint calls `prevent_caching` from `Cacheable`. They must never be cached at CloudFlare or in the browser.

**Domain scoping**: `UserListStateController` reads `Current.domain` and resolves it to the set of relevant `UserList` STI subclasses (e.g. `:music` → `[Music::Albums::UserList, Music::Songs::UserList]`). Mutation controllers do **not** filter by domain — a user editing `Music::Albums::UserList` from a Stimulus fetch on the music subdomain works regardless.

### Schemas (JSON)

**Response — `GET /user_list_state`**
```json
{
  "type": "object",
  "required": ["version", "domain", "lists", "memberships"],
  "properties": {
    "version":    { "type": "integer", "description": "user.updated_at.to_i; monotonic per user" },
    "domain":     { "type": "string", "enum": ["music", "games", "movies", "books"] },
    "lists": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "type", "list_type", "name", "default", "icon"],
        "properties": {
          "id":        { "type": "integer" },
          "type":      { "type": "string", "description": "STI class name e.g. Music::Albums::UserList" },
          "list_type": { "type": "string" },
          "name":      { "type": "string" },
          "default":   { "type": "boolean" },
          "icon":      { "type": ["string", "null"], "description": "icon key from list_type_icons or null for custom" }
        }
      }
    },
    "memberships": {
      "type": "object",
      "description": "Keyed by listable_type → listable_id → array of user_list ids the item belongs to.",
      "additionalProperties": {
        "type": "object",
        "additionalProperties": {
          "type": "array",
          "items": { "type": "integer" }
        }
      }
    }
  }
}
```

Example body:
```json
{
  "version": 1714234567,
  "domain": "music",
  "lists": [
    {"id": 42, "type": "Music::Albums::UserList", "list_type": "favorites",
     "name": "Favorite Albums", "default": true, "icon": "heart"},
    {"id": 43, "type": "Music::Albums::UserList", "list_type": "listened",
     "name": "Albums I've Listened To", "default": true, "icon": "headphones"},
    {"id": 99, "type": "Music::Albums::UserList", "list_type": "custom",
     "name": "My Top 50 of the 90s", "default": false, "icon": null}
  ],
  "memberships": {
    "Music::Album": {
      "101": [42, 99],
      "207": [42, 43]
    }
  }
}
```

**Request — `POST /user_lists`** (custom-list create, optionally with an item)
```json
{
  "type": "object",
  "required": ["user_list"],
  "properties": {
    "user_list": {
      "type": "object",
      "required": ["type", "name"],
      "properties": {
        "type":        {"type": "string", "enum": [
          "Music::Albums::UserList", "Music::Songs::UserList",
          "Games::UserList",         "Movies::UserList"
        ]},
        "name":        {"type": "string", "minLength": 1, "maxLength": 255},
        "description": {"type": ["string", "null"]},
        "public":      {"type": "boolean"},
        "listable_id": {"type": ["integer", "null"], "description": "If present, also add this listable to the new list (atomic)."}
      },
      "additionalProperties": false
    }
  }
}
```
Server forces `list_type = :custom`. If `listable_id` is supplied, the controller creates the `UserList` and `UserListItem` in a single transaction; on validation failure, neither persists.

**Response — `POST /user_lists`** (201)
```json
{
  "user_list":      { "$ref": "#/definitions/UserListSummary" },
  "user_list_item": { "$ref": "#/definitions/UserListItemSummary" }
}
```
`user_list_item` is omitted when no `listable_id` was supplied.

**Request — `POST /user_lists/:user_list_id/items`**
```json
{
  "type": "object",
  "required": ["user_list_item"],
  "properties": {
    "user_list_item": {
      "type": "object",
      "required": ["listable_id"],
      "properties": {
        "listable_id": {"type": "integer"}
      },
      "additionalProperties": false
    }
  }
}
```
`listable_type` is derived server-side from `user_list.class.listable_class.name`. Clients never pass it.

**Response — `POST /user_lists/:user_list_id/items`** (201)
```json
{ "user_list_item": { "$ref": "#/definitions/UserListItemSummary" } }
```

**Response — `DELETE /user_lists/:user_list_id/items/:id`** (200)
```json
{ "ok": true }
```

**`UserListSummary`** (response definition reused above)
```json
{
  "type": "object",
  "required": ["id", "type", "list_type", "name", "default", "icon"],
  "properties": {
    "id":          {"type": "integer"},
    "type":        {"type": "string"},
    "list_type":   {"type": "string"},
    "name":        {"type": "string"},
    "description": {"type": ["string", "null"]},
    "public":      {"type": "boolean"},
    "default":     {"type": "boolean"},
    "icon":        {"type": ["string", "null"]}
  }
}
```

**`UserListItemSummary`**
```json
{
  "type": "object",
  "required": ["id", "user_list_id", "listable_type", "listable_id", "position"],
  "properties": {
    "id":            {"type": "integer"},
    "user_list_id":  {"type": "integer"},
    "listable_type": {"type": "string"},
    "listable_id":   {"type": "integer"},
    "position":      {"type": "integer"}
  }
}
```

**Error contract** (4xx)
```json
{
  "error": {
    "code":    "validation_failed",
    "message": "Name can't be blank",
    "details": { "name": ["can't be blank"] }
  }
}
```

Error `code` values: `unauthenticated` (401), `forbidden` (403), `not_found` (404), `validation_failed` (422), `conflict` (409 — duplicate item).

### Authorization (Pundit)

**`web-app/app/policies/user_list_policy.rb`**

| Action     | Rule                                                           |
|------------|----------------------------------------------------------------|
| `create?`  | `user.present?`                                                |

(`show?`, `update?`, `destroy?`, `reorder?`, scope — deferred to 02c.)

**`web-app/app/policies/user_list_item_policy.rb`**

| Action     | Rule                                                           |
|------------|----------------------------------------------------------------|
| `create?`  | `record.user_list.user_id == user&.id`                         |
| `destroy?` | `record.user_list.user_id == user&.id`                         |

For mutation actions, the controller loads `user_list` via `current_user.user_lists.find(params[:user_list_id])` so non-owners never reach the policy at all (404, not 403). The policy is the second line of defence.

### Controllers

Three new controllers under `web-app/app/controllers/`:

- `user_list_state_controller.rb` — single `show` action; emits the JSON state for `current_user` scoped by `Current.domain`.
- `user_lists_controller.rb` — `create` action only in this spec. Forces `list_type = :custom`. If `listable_id` is supplied, also creates the item in a transaction.
- `user_list_items_controller.rb` — `create` and `destroy`.

All three:
- Inherit `ApplicationController`.
- `before_action :require_signed_in!` (new helper — see Implementation Notes below).
- `before_action :prevent_caching`.
- `respond_to :json` only.
- Pundit `authorize` on every mutating action.
- Rescue `Pundit::NotAuthorizedError` → JSON `{"error": {"code": "forbidden"}}`, status 403.
- Rescue `ActiveRecord::RecordNotFound` → JSON `{"error": {"code": "not_found"}}`, status 404.
- Rescue `ActiveRecord::RecordInvalid` → JSON `{"error": {"code": "validation_failed", ...}}`, status 422.

The default `ApplicationController#user_not_authorized` renders HTML/redirect — it must be overridden (or rescued separately) on these JSON-only controllers.

### ViewComponents

**`UserList::CardWidgetComponent`** — `web-app/app/components/user_list/card_widget_component.{rb,html.erb}`

Args: `listable:` (any `Music::Album`, `Music::Song`, `Games::Game`, `Movies::Movie`).

Renders a single inline element shaped like:

```erb
<%# reference only %>
<div class="user-list-widget"
     data-controller="user-list-widget"
     data-user-list-widget-listable-type-value="Music::Album"
     data-user-list-widget-listable-id-value="42">
  <div data-user-list-widget-target="iconStrip" class="flex gap-1 hidden"></div>
  <button type="button"
          class="btn btn-sm btn-ghost"
          data-action="click->user-list-widget#open"
          data-user-list-widget-target="button">
    <%= icon "plus", library: "lucide", class: "size-4" %>
    <span data-user-list-widget-target="label">Add to list</span>
  </button>
</div>
```

The component is a **dumb shell** — it renders identically for every visitor (anonymous or signed-in) so the HTML is CloudFlare-cacheable. The Stimulus controller fills in icons + count + label client-side.

**`UserList::ModalComponent`** — singleton, rendered once per page in domain layouts.

`web-app/app/components/user_list/modal_component.{rb,html.erb}`. Renders a `<dialog id="user_list_modal" class="modal">` with:
- Title row showing the current item's title (filled by the controller from a `data-` attribute on the trigger button).
- A list of the user's lists with checkboxes (rendered as a `<template>` cloned by JS — empty in initial HTML, populated from `localStorage`).
- An inline "Create a new list" form (`name` input, `description` textarea, optional `public` checkbox, submit button).
- DaisyUI `modal-box` / `modal-backdrop` structure.

**`Toast::RegionComponent`** — singleton, rendered once per page in domain layouts.

`web-app/app/components/toast/region_component.{rb,html.erb}`. Just `<div id="toast-region" class="toast toast-end" data-controller="toast"></div>`. Empty by default.

**Icons — `rails_icons` gem with Lucide**

This spec adopts [`rails_icons`](https://github.com/Rails-Designer/rails_icons) (v1.8+) backed by [Lucide](https://lucide.dev/) as the project-wide icon library. Lucide is ISC-licensed, ~1,600 icons, actively maintained through 2026, stroke-based with `currentColor`, fits DaisyUI's aesthetic and Tailwind v4 `size-*` utilities cleanly.

One-time setup (during implementation):
```bash
bundle add rails_icons
bin/rails generate rails_icons:install --libraries=lucide
```
This vendors only the Lucide icon set into the app. Other libraries are not installed.

Server-side usage (ViewComponents, ERB):
```erb
<%= icon "heart", library: "lucide", class: "size-4 text-primary" %>
```

Client-side usage (Stimulus): the JSON state response carries the icon name (e.g. `"icon": "heart"`) and the controller renders an inline `<svg>` for it. Two reasonable approaches — pick whichever the implementer prefers:

1. **Pre-rendered hidden template**: render every distinct Lucide icon needed (the union of all `list_type_icons` values across subclasses, plus `plus` and `check`) once into a hidden `<template id="user-list-icons">` block in the domain layout via `rails_icons`. The Stimulus controller clones nodes from it by name.
2. **Bundle Lucide on the JS side**: `npm install lucide`, import `createIcons, icons` and call `createIcons({ icons })` after the controller writes `<i data-lucide="heart">` placeholders. Slightly heavier JS bundle (~20KB) but no template plumbing.

Approach (1) is recommended because it keeps the JS bundle small and reuses the same server-rendered SVG output everywhere.

Project-wide implication: with `rails_icons` installed, **other features can adopt it too**. This spec doesn't mandate that — it just installs the gem and uses it for the widget. Any future spec wanting an icon should use the same `icon "name", library: "lucide", ...` helper.

### Stimulus Controllers (JavaScript)

All three controllers register globally in `web-app/app/javascript/controllers/index.js` (run `bin/rails stimulus:manifest:update` after creating them). They are loaded on every domain because every layout loads `application.js`.

**`user_list_state_controller.js`** — singleton, attached to `<body data-controller="... user-list-state">` in each domain layout.

Storage key: `tg:user_list_state:<domain>` where `<domain>` is read from `document.body.dataset.domain` (already set; verify in layouts during implementation).

```javascript
// reference only — public surface
class UserListStateController extends Controller {
  static values = { url: { type: String, default: "/user_list_state" } }

  connect()       // 1) read localStorage; if present, dispatch user-list-state:loaded synchronously.
                  // 2) fetch this.urlValue; on response, if version > stored.version, write + dispatch user-list-state:updated.
                  // listens for "auth:success" / "auth:signout" on window to re-fetch / clear.

  refresh()       // re-fetch and broadcast
  applyMutation(  // called by user-list-modal after a successful add/remove; updates localStorage optimistically and broadcasts.
    listableType, listableId, listIds
  )
  state()         // returns current state object (from memory cache)
}
```

Storage shape (in localStorage):
```json
{ "version": 1714234567, "domain": "music", "lists": [...], "memberships": {...} }
```

`setItem` is wrapped in `try/catch`. On `QuotaExceededError`, log a warning and continue without persistence — the in-memory cache + per-page fetch still works.

**`user_list_widget_controller.js`** — one per item card.

```javascript
// reference only
static values  = { listableType: String, listableId: Number }
static targets = ["iconStrip", "button", "label"]

connect()       // listens for "user-list-state:loaded" / "user-list-state:updated" on window; calls render()

render()        // reads state; for the (type,id) pair, fetches list ids;
                // looks up each list's icon via state.lists.find(l => l.id === listId).icon;
                // renders <svg> children into iconStrip; updates label ("On 2 lists" / "Add to list");
                // toggles button color (btn-ghost vs btn-primary) when on ≥1 list.

open()          // if anonymous (no state cached AND not signed in): document.getElementById('login_modal').showModal()
                // else: dispatches "user-list-modal:open" on window with detail {listableType, listableId}.
```

"Anonymous" detection: read `document.body.dataset.signedIn === "true"`. The layout sets this attribute server-side based on `current_user.present?`. Because this layout fragment is **on uncached layouts only** — wait: cached pages also use this layout. The layout is shared, but cached pages render with `current_user` nil, so `data-signed-in="false"` is what CDN-cached HTML always carries. That's correct: an anonymous-looking shell. Sign-in detection at the page level relies instead on **`localStorage` having state**: if `tg:user_list_state:<domain>` exists, the user is signed in (or recently was). If not, treat as anonymous.

A signed-in user landing on a page they've never visited will momentarily appear anonymous to the widget. To handle this, `user-list-state` waits for either a `localStorage` hit OR a successful 200 from `/user_list_state` before setting an in-memory `signedIn` flag. The widget's `open()` consults that flag. On a 401, the widget treats them as anonymous.

**`user_list_modal_controller.js`** — singleton, attached to the `<dialog>`.

```javascript
// reference only
static targets = ["title", "existingLists", "createForm", "nameInput",
                  "descriptionInput", "publicInput", "submitButton"]
static values  = { csrfToken: String }

connect()       // listens for "user-list-modal:open" on window; renders the dialog.

renderForItem(listableType, listableId)
                // reads state from the user-list-state controller (via window.dispatchEvent + getter, OR via a singleton accessor — implementation choice).
                // Fills existingLists with one row per UserList in the same domain that accepts this listableType:
                //   <label><input type="checkbox" data-list-id="..." {checked if member}> {name} {default-icon}</label>
                // Toggling a checkbox calls add(listId) or remove(listId).
                // Creating a list calls createList().
                // On any success: calls user-list-state controller's applyMutation() and dispatches "toast:show".
                // On any error: dispatches "toast:show" type=error with the API message.

add(listId)
remove(listId)
createList()    // POST /user_lists with {type, name, description, public, listable_id: currentItemId}
```

**`toast_controller.js`** — singleton.

```javascript
// reference only
connect()       // listens for "toast:show" on window with detail {type, message, ttl}
showToast(detail)  // appends a <div class="alert alert-{success|error|info}"> to this.element,
                   // auto-removes after detail.ttl || 4000 ms.
```

### Card Refactors

**`web-app/app/components/music/albums/card_component/card_component.html.erb`** — the heaviest change.

Today the entire card is a `link_to_album do ... end` block — i.e. an `<a>` element. We must change it so the outer element is a `<div class="card">` with explicit interior links and the widget inside.

```erb
<%# reference only — restructured shape %>
<div class="card bg-base-100 shadow-xl hover:shadow-2xl transition-shadow"
     data-listable-type="Music::Album"
     data-listable-id="<%= item_album.id %>">
  <%= link_to_album item_album, ranking_configuration, data: { turbo_frame: "_top" } do %>
    <figure class="px-4 pt-4">
      <%# image (unchanged) %>
    </figure>
  <% end %>
  <div class="card-body p-4">
    <div class="flex items-start justify-between mb-2">
      <%# rank badge + year (unchanged) %>
    </div>
    <h2 class="card-title text-lg font-bold text-base-content mb-1">
      <%= link_to_album item_album, ranking_configuration, class: "hover:text-primary",
                                                            data: { turbo_frame: "_top" } %>
    </h2>
    <p class="text-base-content/80 mb-3">by <%= item_album.artists.map(&:name).join(", ") %></p>
    <%# categories (unchanged) %>
    <div class="card-actions justify-end mt-2">
      <%= render UserList::CardWidgetComponent.new(listable: item_album) %>
    </div>
  </div>
</div>
```

**`web-app/app/components/music/songs/list_item_component/list_item_component.html.erb`** — additive.

Add a final `<td>` rendering the widget. Update `web-app/app/views/music/songs/ranked_items/index.html.erb` (and any other view that renders the songs table) to add a matching empty `<th>` in the table header. The new cell sets `data-listable-type="Music::Song"` and `data-listable-id="<%= song.id %>"` on a wrapping element so the widget can read them.

**`web-app/app/components/games/card_component.html.erb`** — additive.

Add `data-listable-type="Games::Game"` and `data-listable-id="<%= item_game.id %>"` to the outer `<div class="card">`. Add `<div class="card-actions justify-end"><%= render UserList::CardWidgetComponent.new(listable: item_game) %></div>` to the bottom of `card-body`.

**Show pages — Album, Song, Game**

Render the widget once near the title on each show view. Templates touched (verify exact paths during implementation):
- `web-app/app/views/music/albums/show.html.erb`
- `web-app/app/views/music/songs/show.html.erb`
- `web-app/app/views/games/games/show.html.erb`

Wrap the widget in a `<div data-listable-type="..." data-listable-id="...">` so the same Stimulus controller can find it.

**Movies / Books**: no changes. Movies has no item pages yet; books domain doesn't exist.

### Layout changes (per domain)

For each of `web-app/app/views/layouts/{music,games,movies}/application.html.erb`:

- Add `data-controller="user-list-state"` to `<body>` (or merge with existing controllers).
- Add `data-domain="<%= Current.domain %>"` to `<body>`.
- Add `data-signed-in="<%= signed_in? %>"` to `<body>`.
- Render the user-list modal once near the existing `<dialog id="login_modal">`.
- Render the toast region.
- Include the icon sprite partial (only if you added one).

### Behaviors (pre/postconditions)

**State hydration on page load**
- Pre: signed-in user navigates to a cached page (or any page) on a domain.
- Post: within ~50ms of `connect()`, every visible card's widget shows the correct icon strip and count from `localStorage`. Within 1 round-trip of `/user_list_state`, the cache is up to date.
- Edge cases:
  - First visit (no localStorage): widget stays in "anonymous-looking" Add-to-list state until the fetch returns; then re-renders.
  - 401 from `/user_list_state` (signed out in another tab): wipe the localStorage key, leave widgets in anonymous state.
  - QuotaExceededError on `localStorage.setItem`: log + continue with in-memory cache only.

**Add to existing list**
- Pre: signed-in; opens modal; toggles a list checkbox to ON.
- Post: `UserListItem` is created; `localStorage.memberships[type][id]` includes `listId`; widget re-renders; toast shows success.
- Edge cases:
  - Already in the list (race): API returns 409; modal re-syncs from response state; toast shows "Already added".
  - Listable type mismatch: API returns 422 (impossible from this UI but defended at the API layer).
  - 403 (someone else's list — also impossible from this UI): wipe localStorage, refresh.

**Remove from list**
- Pre: signed-in; toggles a list checkbox to OFF.
- Post: `UserListItem` destroyed; `localStorage` updated; widget re-renders; toast shows "Removed".

**Create new list (with optional add)**
- Pre: signed-in; types a name (and optional description) in the inline create form; clicks Save.
- Post: A new custom `UserList` exists with `list_type = :custom`. If the modal was opened from an item context, the item is also added in the same transaction. `localStorage.lists` includes the new entry; `localStorage.memberships` includes the new membership.
- Edge cases:
  - Validation failure (blank name, etc.): inline error appears next to the field; nothing persists.
  - Concurrent default-list creation race (impossible from this UI — API forces `:custom`): API rejects with 422.

**Anonymous click**
- Pre: not signed in; clicks any card's "Add to list" button.
- Post: `login_modal.showModal()` runs; the user signs in; the page reloads (existing `reload_after_auth: true` flow); state hydrates; widget shows their state.

### Non-Functionals

- **Auth**: `/user_list_state` and all mutations require a signed-in user. 401 with the unauthenticated error code if not.
- **Caching**: All four endpoints set `Cache-Control: no-store, no-cache, must-revalidate, private`.
- **Performance budgets**:
  - `/user_list_state` for a user with 5,000 items: p95 ≤ 200ms server-side, payload ≤ 100KB gzipped.
  - Widget `connect()` to first paint of icon strip: ≤ 50ms when localStorage hit (no network).
  - Mutation round-trip: ≤ 300ms p95 server-side.
  - No N+1: state endpoint loads `user_lists` (one query) and `user_list_items` (one query, filtered to relevant `listable_type`s) and shapes the response in memory.
- **Concurrency**: Optimistic localStorage updates roll back on API error (the Stimulus controller writes the new shape *after* the API confirms; UI shows a transient "saving…" state otherwise).
- **localStorage quota**: every `setItem` is in `try/catch`; quota errors degrade to in-memory only without breaking the widget.
- **CloudFlare safety**: cached HTML never contains user-specific markup. The widget's initial DOM is identical for every visitor, including anonymous.
- **Performance for the cards themselves**: rendering N widget shells on a 100-item page is a small ViewComponent cost only — they have no data dependencies. Verify no N+1 fires in the card render path.

## Acceptance Criteria

- [ ] `GET /user_list_state` (signed-in) returns current-domain lists + memberships for the user; payload matches schema.
- [ ] `GET /user_list_state` (anonymous) returns 401 with `unauthenticated` error code.
- [ ] `POST /user_lists` creates a `:custom` list (type forced server-side even if client sends another value).
- [ ] `POST /user_lists` with a `listable_id` creates the list AND a `UserListItem` in a single transaction; rolling back either rolls back both.
- [ ] `POST /user_lists/:user_list_id/items` adds the item; returns the created summary.
- [ ] `POST /user_lists/:user_list_id/items` with a duplicate listable returns 409 `conflict`.
- [ ] `POST /user_lists/:user_list_id/items` with a wrong-typed listable returns 422 `validation_failed`.
- [ ] `DELETE /user_lists/:user_list_id/items/:id` removes the item; returns `{"ok": true}`.
- [ ] Mutation endpoints accessed by a non-owner return 404 (controller-level `current_user.user_lists.find` filter), not 403.
- [ ] All four endpoints respond with `Cache-Control: no-store, no-cache, must-revalidate, private`.
- [ ] `UserListItem#after_commit :touch_user` bumps `user.updated_at`; `version` in `/user_list_state` reflects it.
- [ ] `UserList#after_commit :touch_user` bumps `user.updated_at`.
- [ ] Each STI subclass declares `self.list_type_icons` covering every non-`:custom` list type.
- [ ] `Music::Albums::CardComponent` outer element is a `<div>`, not an `<a>`. Existing tests / visual regression hold (manual screenshot check).
- [ ] `Music::Songs::ListItemComponent` renders an additional `<td>` for the widget; the index view's `<thead>` has the matching empty `<th>`.
- [ ] `Games::CardComponent` renders the widget in a `card-actions` row.
- [ ] Album / Song / Game show pages render the widget near the title.
- [ ] On a cached `/albums` page, signed-in users see correct per-list icons on each card after `localStorage` hydration; anonymous users see plain "Add to list" buttons.
- [ ] Anonymous click on the widget opens `<dialog id="login_modal">`. Successful sign-in reloads the page and hydrates the widget.
- [ ] `localStorage` `QuotaExceededError` is caught; widget continues to function with in-memory state only.
- [ ] Toast appears on every successful add/remove/create and on every error path.
- [ ] Stimulus controller manifest (`controllers/index.js`) is updated for `user-list-state`, `user-list-widget`, `user-list-modal`, `toast`.
- [ ] Pundit policies prevent non-owner mutations (covered by tests).
- [ ] Existing test suite still green; new controller specs cover all 4 endpoints, all 6 error codes, the duplicate-item conflict, the wrong-type validation, the create-and-add transaction, and the unauthenticated path.

### Golden Examples

**Example 1 — first visit (no localStorage), 5,000-item user**
```
1. Signed-in user with 5,000 memberships across 12 lists in the music domain
   visits https://thegreatestmusic.org/albums
2. The cached HTML renders 100 album cards with empty widgets
3. user-list-state Stimulus controller connects:
   - localStorage MISS for tg:user_list_state:music
   - fetches GET /user_list_state
   - response: 200, ~60KB gzipped, version=1714234567
   - writes localStorage, dispatches user-list-state:loaded
4. Each user-list-widget controller renders:
   - albums in user's "Favorites" list show a heart icon
   - albums in user's "Listened" list show a headphones icon
   - albums in 2+ custom lists show "+2" pill
5. End-to-end first-paint of icons: ~one /user_list_state round-trip
```

**Example 2 — anonymous click**
```
1. Anonymous visitor on /albums clicks "Add to list" on an album card
2. user-list-widget#open detects no localStorage and dispatches login_modal.showModal()
3. User signs in via Firebase
4. Existing reload_after_auth: true triggers a full page reload
5. On reload, /user_list_state hydrates the now-signed-in user's state
```

**Example 3 — create-and-add atomically**
```
1. Signed-in user clicks "Add to list" on album 9876 (id=9876, Music::Album)
2. Modal opens; user types name="My Top 50 of the 90s", description="…", clicks Save
3. POST /user_lists with body:
   { "user_list": { "type": "Music::Albums::UserList",
                    "name": "My Top 50 of the 90s",
                    "description": "…",
                    "listable_id": 9876 } }
4. Server creates Music::Albums::UserList(list_type=:custom) AND UserListItem in one transaction
5. Response 201:
   { "user_list":      { "id": 99, "type": "Music::Albums::UserList", ... },
     "user_list_item": { "id": 555, "user_list_id": 99, "listable_type": "Music::Album",
                          "listable_id": 9876, "position": 1 } }
6. Stimulus controller updates localStorage:
   - state.lists.push({id: 99, ...})
   - state.memberships["Music::Album"]["9876"].push(99)
7. Widget re-renders; toast: "Added to My Top 50 of the 90s"
```

**Example 4 — duplicate add (409)**
```
1. Signed-in user opens modal for album 9876
2. UI shows the album is already in "Favorites" — checkbox is checked
3. From another tab, the user removes it
4. From this tab, user clicks "Favorites" thinking they're toggling on (it was checked)
5. POST /user_lists/42/items {"user_list_item": {"listable_id": 9876}}
6. Server: Listable id 9876 is no longer in list 42 (the other tab removed it),
   so the request actually succeeds → 201. localStorage updates.
   (The 409 case is the genuinely concurrent add-from-two-tabs scenario.)
```

**Example 5 — wrong-type prevention**
```
1. Direct API call (not through UI):
   POST /user_lists/42/items {"user_list_item": {"listable_id": 9876}}
   where list 42 is a Music::Albums::UserList
   but 9876 is a Music::Song id
2. Controller derives listable_type from user_list.class.listable_class.name = "Music::Album"
3. UserListItem validation listable_type_compatible_with_user_list rejects it
4. 422 { "error": { "code": "validation_failed",
                    "message": "Listable type ... is not compatible ...",
                    "details": { "listable_type": ["..."] } } }
```

---

## Agent Hand-Off

### Constraints
- Mirror existing project patterns. Stimulus controllers go in `web-app/app/javascript/controllers/` and register via `bin/rails stimulus:manifest:update`. ViewComponents follow the sidecar-directory convention. Pundit policies follow the existing `application_policy.rb` shape.
- One new gem allowed: `rails_icons` (Lucide library only). No other new gems. No new JS libraries (no SortableJS — that's `02c`'s problem). If approach (2) is chosen for client-side icons, the `lucide` npm package may be added.
- Snippet budget: ≤40 lines per snippet in the spec; the implementer writes the actual code in the repo.
- Do **not** alter the data model schema. `after_commit :touch_user` is a behavior change only.
- Do **not** ship the `/my/lists` dashboard, list show page, drag-and-drop, view-mode UI, or `completed_on` editing — those are 02c.
- Do **not** ship public-list discovery or "consumed" badges beyond the per-list-type icon strip — that's 02d.
- Movies and books require **no** card refactors in this spec.
- Album card refactor is **in scope** for this spec; do it carefully and verify the cached `/albums` page renders identically (modulo the new widget) for anonymous users via screenshot.

### Required Outputs
- New / modified files listed under "Key Files Touched".
- Minitest coverage for every Acceptance Criteria bullet that is server-side.
- Manual visual verification of the album-card refactor (cached anonymous render) and the signed-in state hydration on each domain (music + games).
- Updated feature doc `docs/features/user-lists.md` with a new "Add-to-List Widget" section.
- Filled-in "Implementation Notes" and "Deviations" sections in this spec.

### Sub-Agent Plan
1. `codebase-pattern-finder` → confirm existing Stimulus + ViewComponent + Pundit + JSON-controller patterns to mirror.
2. `codebase-analyzer` → verify `Current.domain`, `signed_in?`, `current_user`, layout `data-` attributes, and the auth-modal trigger before writing the layout edits.
3. `web-search-researcher` → only if an icon library question comes up that the codebase doesn't answer.
4. `technical-writer` → after implementation, update class docs and `docs/features/user-lists.md`.

### Test Seed / Fixtures
- Reuse `test/fixtures/user_lists.yml` and `test/fixtures/user_list_items.yml` from Part 1.
- Add no new fixtures — controller specs that need clean state should `User.create!` and use `default_user_list_for(...)`.

---

## Implementation Notes
- **Approach taken**:
  - Backend first: model `touch_user` callbacks + `list_type_icons` declarations, then Pundit policies, then three JSON controllers wired through a shared `JsonErrorResponses` concern. All four endpoints set `Cache-Control: no-store, no-cache, must-revalidate, private` via the existing `Cacheable#prevent_caching`.
  - Frontend: three sidecar ViewComponents (`UserLists::CardWidgetComponent`, `UserLists::ModalComponent`, `Toast::RegionComponent`), four Stimulus controllers (`user-list-state` singleton on `<body>`, plus widget / modal / toast), and a hidden Lucide icon `<template>` partial.
  - Icon library: `rails_icons` 1.8 with the Lucide set. The hidden `<template id="user-list-icons">` holds the union of icons used by every `list_type_icons` map (heart, headphones, bookmark, check, trophy, gamepad-2, eye, plus); the widget Stimulus controller clones nodes from it by `data-icon` name. Server-side, ViewComponents call `helpers.icon` (the bare `icon` helper isn't on `ViewComponent::Base`'s instance methods).
- **Important decisions**:
  - **Component namespace**: spec called for `UserList::CardWidgetComponent` etc. but `UserList` is the STI base class — re-opening it as a module raises `TypeError: UserList is not a module`. Components live under `UserLists::*` (pluralized namespace, matching `UserListsController`). Stimulus and Rails controllers retain the singular `user_list_*` naming.
  - **Pundit `policy_class:`**: STI subclasses (e.g. `Music::Albums::UserList`) caused Pundit to look for `Music::Albums::UserListPolicy`. Authorize calls pass `policy_class: UserListPolicy` / `UserListItemPolicy` so a single shared policy file applies regardless of subclass.
  - **Touch guard**: `after_commit :touch_user` was crashing during `User#destroy` cascades (`Cannot touch on a new or destroyed record object`). Both touch helpers early-return for `nil`, `destroyed?`, and `new_record?` users.
  - **`require_signed_in!`**: added to `ApplicationController` rather than a concern. Returns JSON 401 on JSON requests; redirects on HTML.
  - **CSRF token via state endpoint, not `<meta>`**: the spec said "standard Rails meta-tag CSRF flow" but on a CDN-cached page the meta token belongs to whoever (or no one) rendered the cache. `/user_list_state` (uncached) now returns `csrf_token: form_authenticity_token`. The state Stimulus controller holds it in memory only — never written to localStorage. The modal `await stateCtrl.ensureCsrf()` before every mutation; concurrent callers share an `_inflightRefresh` promise. `JsonErrorResponses` rescues `ActionController::InvalidAuthenticityToken` so an unlucky race renders the standard JSON error shape rather than a Rails HTML page.
  - **Memberships carry item ids**: spec example showed `memberships[type][id] = [list_id, ...]`. To make in-modal removal work without an extra round-trip, the actual response uses `[{list_id, item_id}, ...]` tuples. `applyMutation` accepts a full `memberships` array; the modal's `_findItemId(listId)` reads from that map for DELETE.
  - **localStorage schema versioning**: persisted state is stamped with `_schema: 2`; on hydrate, mismatched entries are discarded and a fresh `/user_list_state` fetch wins. Bump the constant when shape changes again. The original implementation only updated the localStorage cache when `data.version > cache.version`; that was suppressing legitimate updates because optimistic `applyMutation` stamps the cache with `Date.now()/1000`, often ahead of the server's `user.updated_at.to_i`. `_doRefresh` now always replaces the cache from the network response (the version field stays for client-side optimistic-update bookkeeping only).
  - **Stimulus framework property shadowing**: an early implementation set `this.context = event.detail` on the modal controller. Stimulus uses `this.context.scope.targets` internally for every target lookup, so this clobbered the framework and broke every target getter. Renamed to `this.openContext`.
  - **Modal UX**: the create-list form is collapsed inside a `<details>` disclosure (`+ Create a new list`), reset on each open. The Create button is `disabled` until the name has content, `<form novalidate>` suppresses HTML5 popups. The existing-lists region uses `max-h-64 overflow-y-auto` with `min-w-0 break-words` on rows so long names wrap and many lists scroll inside the modal instead of pushing the create form down.
  - **`mount RailsIcons::Engine`**: scoped to `Rails.env.development?` so the icon-preview UI doesn't ship to production.

### Key Files Touched (paths only)
**Routes & controllers (new)**
- `web-app/config/routes.rb`
- `web-app/app/controllers/user_list_state_controller.rb`
- `web-app/app/controllers/user_lists_controller.rb`
- `web-app/app/controllers/user_list_items_controller.rb`

**Concerns / helpers (new or modified)**
- `web-app/app/controllers/application_controller.rb` — add `require_signed_in!` helper if not present.
- `web-app/app/controllers/concerns/json_error_responses.rb` — small concern with `render_unauthorized`, `render_forbidden`, `render_not_found`, `render_validation_failed`, `render_conflict`. (Optional but encouraged — keeps the three new controllers terse.)

**Models (modified)**
- `web-app/app/models/user_list_item.rb` — `after_commit :touch_user`
- `web-app/app/models/user_list.rb` — `after_commit :touch_user`
- `web-app/app/models/music/albums/user_list.rb` — `self.list_type_icons`
- `web-app/app/models/music/songs/user_list.rb` — `self.list_type_icons`
- `web-app/app/models/games/user_list.rb` — `self.list_type_icons`
- `web-app/app/models/movies/user_list.rb` — `self.list_type_icons`

**Pundit policies (new)**
- `web-app/app/policies/user_list_policy.rb`
- `web-app/app/policies/user_list_item_policy.rb`

**Pundit policy tests (new)**
- `web-app/test/policies/user_list_policy_test.rb`
- `web-app/test/policies/user_list_item_policy_test.rb`

**ViewComponents (new — pluralized namespace, see Deviations)**
- `web-app/app/components/user_lists/card_widget_component.rb` + sidecar template
- `web-app/app/components/user_lists/modal_component.rb` + sidecar template
- `web-app/app/components/toast/region_component.rb` + sidecar template

**Stimulus controllers (new)**
- `web-app/app/javascript/controllers/user_list_state_controller.js`
- `web-app/app/javascript/controllers/user_list_widget_controller.js`
- `web-app/app/javascript/controllers/user_list_modal_controller.js`
- `web-app/app/javascript/controllers/toast_controller.js`
- `web-app/app/javascript/controllers/index.js` — auto-regenerated via `bin/rails stimulus:manifest:update`

**Views (modified)**
- `web-app/app/views/layouts/music/application.html.erb`
- `web-app/app/views/layouts/games/application.html.erb`
- `web-app/app/views/layouts/movies/application.html.erb`
- `web-app/app/components/music/albums/card_component/card_component.html.erb` — restructured
- `web-app/app/components/music/songs/list_item_component/list_item_component.html.erb` — new `<td>`
- `web-app/app/components/games/card_component.html.erb` — additive widget
- `web-app/app/views/music/songs/ranked_items/index.html.erb` — new `<th>`
- `web-app/app/views/music/albums/show.html.erb` — widget near title
- `web-app/app/views/music/songs/show.html.erb` — widget near title
- `web-app/app/views/games/games/show.html.erb` — widget near title

**Gem & icon plumbing**
- `web-app/Gemfile` + `web-app/Gemfile.lock` — added `rails_icons` ~> 1.8.
- `web-app/config/initializers/rails_icons.rb` — generated by `bin/rails generate rails_icons:install --libraries=lucide`.
- `web-app/app/assets/svg/icons/lucide/` — vendored Lucide subset (1703 SVGs).
- `web-app/app/views/shared/_user_list_icon_template.html.erb` — hidden `<template>` with the 8 Lucide icons the widget needs.
- `web-app/config/routes.rb` — `mount RailsIcons::Engine, at: "/rails_icons" if Rails.env.development?` (preview UI not shipped to production).

**Documentation**
- `docs/features/user-lists.md` — new "Add-to-List Widget" section, including final shape decisions (CSRF flow, membership tuples, schema versioning, namespace).

### Challenges & Resolutions
- **`UserList` namespace clash**: re-opening the STI base class as a module raised `TypeError: UserList is not a module`. Resolved by pluralizing the component namespace to `UserLists::*`.
- **STI Pundit policy lookup**: Pundit derived `Music::Albums::UserListPolicy` from STI subclasses. Resolved by passing explicit `policy_class:` to every `authorize` call.
- **Touch on destroyed user**: cascade deletes from `User#destroy` triggered `after_commit :touch_user` after the user was already destroyed. Resolved with `nil? || destroyed? || new_record?` guards.
- **`icon` helper inside ViewComponent**: `rails_icons` injects `icon` into `ActionView`, but `ViewComponent::Base` doesn't include view helpers automatically. Resolved by calling `helpers.icon` from the component template.
- **CSRF token on cached pages**: the `<meta name="csrf-token">` baked into a CDN-cached page belongs to whoever rendered the cache (or no one) — every mutation 422'd. Resolved by adding `csrf_token: form_authenticity_token` to the uncached `/user_list_state` response, holding it in-memory in the state Stimulus controller, and `await ensureCsrf()` before every mutation. Also rescued `ActionController::InvalidAuthenticityToken` in `JsonErrorResponses` so the racey first-fire-before-fetch case still returns the standard JSON error shape.
- **Stimulus `this.context` clobber**: assigning `this.context = event.detail` on the modal controller broke every target getter (Stimulus stores `scope.targets` under `this.context.scope`). Renamed the per-open property to `this.openContext`.
- **Item-id absence in bulk state**: an initial implementation deferred the `UserListItem.id` to 02c, leaving `_findItemId` returning `null` and DELETE unreachable from the modal UI. Resolved by extending `memberships[type][id]` from `[list_id]` to `[{list_id, item_id}]` tuples, plumbing the new shape through `applyMutation`, the widget's `_membershipLists`, and the modal's `_memberMap` / `_findItemId`.
- **localStorage shape drift**: after the membership-shape change, users with cached state hydrated against the old shape and saw nothing on their cards (and the network refresh was suppressed by a `version > cache.version` optimization that lost to `applyMutation`'s `Date.now()` stamps). Resolved by stamping persisted state with a `_schema` version and discarding non-matching caches on hydrate, plus making `_doRefresh` always replace the cache from the network response.
- **Modal UX (create form)**: the inline create form was being submitted accidentally when users only meant to dismiss after toggling existing-list checkboxes. Resolved by collapsing the create form inside a `<details>` disclosure, gating the Create button on a non-empty name, `novalidate`-ing the form, and renaming the dismiss button to "Done".
- **Modal UX (long names / many lists)**: long list names caused horizontal modal scroll; many lists pushed the create form below the viewport. Resolved by `min-w-0 break-words` on row labels and `max-h-64 overflow-y-auto` on the lists region.

### Deviations From Plan
- **Component namespace** uses `UserLists::*` (plural) instead of the spec's `UserList::*` (singular) due to the STI class clash. All other naming follows the spec.
- **CSRF flow** uses a token issued via `/user_list_state` instead of the spec's `<meta name="csrf-token">`. The meta-tag approach is unsafe for CDN-cached HTML; the new approach is purpose-built for it.
- **Memberships shape** is `[{list_id, item_id}, ...]` tuples instead of the spec's `[list_id, ...]` array. Required to make modal removal work without a separate lookup endpoint. The spec example response and the feature doc both reflect the new shape.
- **`applyMutation` argument names**: the spec sketched `listIds` for the membership array; implementation uses `memberships` to reflect the tuple shape change.

## Acceptance Results
All acceptance criteria pass. **4135 tests**, 10783 assertions, 0 failures, 0 errors. Manual smoke testing on a logged-in account against `dev.thegreatestmusic.org`, `dev.thegreatest.games`, and the music/album/game show pages: anonymous shells render identically for cached vs signed-in users; signed-in users see the per-list-type icon strip correctly after hydration; add-to-list, remove-from-list, and inline create-and-add all round-trip end-to-end with optimistic UI + toast feedback; CSRF token refresh races handled; localStorage shape drift handled by schema versioning. `/user_list_state` returns 401 + `Cache-Control: no-store, private` when anonymous and `Cache-Control: no-store` on every mutation endpoint.

Code review (`feature-dev:code-reviewer`) surfaced two real issues post-merge — both addressed before completion: (1) DELETE was unreachable from the modal because of the deferred-item-id design (now fixed by carrying tuples in the bulk state); (2) `ActionController::InvalidAuthenticityToken` wasn't in the `JsonErrorResponses` rescue list (now added). Other findings (CSRF flow, Pundit/STI, transaction rollback, conflict detection, Cache-Control, naming consistency, namespace clash, footer order) all came back clean.

## Future Improvements
- "Consumed" badge style upgrade (full overlay with completion date).
- Per-page scoped state endpoint (`?listable_ids=…`) if payloads ever exceed quota for some user.
- Service-Worker–backed offline mode for the widget.

## Related PRs
- _to be filled when the PR is opened_

## Documentation Updated
- [x] `docs/features/user-lists.md` — added "Add-to-List Widget" section documenting endpoints, Stimulus controllers, icons, namespace note
- [x] Spec file (this document) — Status, Implementation Notes, Deviations, Acceptance Results
