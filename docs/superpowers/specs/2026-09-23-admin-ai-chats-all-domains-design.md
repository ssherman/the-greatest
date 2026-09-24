# Admin AI Chats for every domain — design

Date: 2026-09-23 · Branch: `worktree-admin-ai-chats`

## Goal

Give books and games admins the AI Chats index and show pages music already has, by turning
music's implementation into one shared implementation rather than copying it. Games has ~4,100
chats in the dev database (on `Games::Game` and `Games::List`) with no way to see them; books has
its first few, written by the import finder against `Books::Book`.

Success: `/admin/ai_chats` works on all three hosts, each shows only its own domain's chats, and
music keeps its URL and helper names. No music-only AI chat code remains.

Non-goals: new features (filters, search, deleting chats), chats on `Category` or movies parents.

## Today

- `Admin::Music::AiChatsController` hard-codes the music parent types in two constants and scopes
  with `music_scoped_ai_chats`: direct parent types, plus list parents via
  `AiChat.with_list_parent_types` (lists are STI, so `parent_type` is the base `"List"`), plus
  chats with no parent.
- `app/views/admin/music/ai_chats/{index,show,_table}.html.erb`.
- `Admin::AiChatsHelper` has three `case` statements over music classes (parent admin path,
  parent type label, parent display name) and two badge-class helpers.
- `Admin::DomainRouting` already records, for every entity and list type, its domain and admin
  path (`ENTITIES`, `LISTS`). The helper's `case` statements duplicate a subset of that.
- `Admin::CorrectionsController` is the precedent: one controller, routed from each domain's admin
  namespace with `controller: "/admin/corrections"`, domain taken from `current_domain`.

## Design

### Routing and controller

- New `Admin::AiChatsController < Admin::BaseController` (generator), including
  `Admin::DomainScopedAuth` and `Pagy::Method`. Actions `index` and `show` keep music's behavior:
  newest first, `includes(:parent, :user)`, 25 per page.
- Each domain's admin block declares `resources :ai_chats, only: [:index, :show],
  controller: "/admin/ai_chats"`. Music's existing line gains the `controller:` option, so its
  path (`/admin/ai_chats`) and helpers (`admin_ai_chats_path`, `admin_ai_chat_path`) do not change.
  Books and games get `admin_books_ai_chats_path` / `admin_games_ai_chats_path` and singulars.
- The controller maps domain → index helper name (same shape as `CorrectionsController::ADMIN_PATHS`)
  and exposes `ai_chats_index_path` and `ai_chat_path_for(chat)` as helper methods, so the shared
  views never name a domain's route helper.
- `show` finds through the domain scope: another domain's chat is a 404.
- `Admin::Music::AiChatsController`, its views directory and its test are deleted.

### Domain scoping

- `Admin::DomainRouting.entity_types_for(domain)` and `.list_types_for(domain)` return the
  `ENTITIES` / `LISTS` keys whose `domain` matches. No new table.
- `AiChat.for_parent_types(entity_types, list_types)` scope: `parent_type IN entity_types`, OR
  parent is a list of one of `list_types` (subquery on the existing `with_list_parent_types`, so no
  ids are loaded into memory), OR `parent_type IS NULL`.
- Parentless chats therefore appear on every domain (decision: they cannot be attributed to a
  domain, and music shows them today).
- Chats whose parent type is registered nowhere (`Category`, movies) appear on no domain. None
  exist in dev.

### Helper

`Admin::AiChatsHelper` keeps its public method names; the bodies read the registry:

- `admin_ai_chat_parent_path`: `DomainRouting.list_config(parent)&.dig(:path)` for a `List`,
  else `DomainRouting.path_for(parent)`. nil when the parent is missing or unregistered.
- `ai_chat_parent_type_label`: for a list, `"#{item_label} List"` from `LISTS` (music's
  "Albums List" becomes "Album List"); otherwise the demodulized class name ("Book", "Game",
  "Artist"). Falls back to `parent_type.demodulize` when the parent record is gone.
- `ai_chat_parent_display_name`: the parent's `name` or `title`, else `"<Class> #<id>"`.
- `ai_chat_type_badge_class`, `ai_chat_provider_badge_class`: unchanged.

### Views and nav

- Views move to `app/views/admin/ai_chats/`, using `ai_chats_index_path` / `ai_chat_path_for`.
  Index subtitle drops "for music content".
- `Admin::DomainNav` gets an "AI Chats" item (`icon: :chat`) for books and games.

## Testing

- `test/controllers/admin/ai_chats_controller_test.rb` replaces the music test and runs per host:
  index 200 on each domain; each domain's show of its own entity chat and list chat is 200; another
  domain's chat is 404 in both directions; a parentless chat is 200 on every domain; admin and
  editor allowed; regular and signed-out users redirected to that domain's root;
  `books_viewer_user` allowed on books and redirected on games; `games_editor_user` the reverse.
  Behavior only, no markup assertions.
- Fixtures (`test/fixtures/ai_chats.yml`): `ranking_chat` is corrected to `parent_type: "List"` +
  `parent_id` (it currently stores `"Books::List"`, which no real row does and which the list
  scope would never match); add a books chat on `war_and_peace` and a games chat on
  `breath_of_the_wild`, so each domain has an entity parent and a list parent.
- Every domain's scope test proves the other two domains' chats are excluded, so a scope that
  returned everything fails.
- Unit: `AiChat.for_parent_types` (model), `DomainRouting.entity_types_for` / `list_types_for`,
  and the rewritten helper for entity, list, unregistered, and missing parents.
- E2E: `e2e/tests/books/admin/ai-chats.spec.ts` and `e2e/tests/games/admin/ai-chats.spec.ts`:
  reach AI Chats from the sidebar, the page renders (table or empty state), and a chat opens when
  one exists.
- Done means: `bin/rails test`, `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`, and the
  E2E specs green after confirming this checkout owns port 3000.

## Rollout

No migration, no data change. Music's URL is unchanged. Merging deploys.

## Follow-up (out of scope)

`Games::Game` creates AI chats but has no `has_many :ai_chats, as: :parent, dependent: :destroy`,
unlike every other parent model, so destroying a game orphans its chats. One-line fix, separate
change.
