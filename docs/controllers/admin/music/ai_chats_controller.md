# Admin::Music::AiChatsController

## Summary
Read-only admin controller for viewing AI Chat records within the music domain. Provides index and show actions for inspecting AI interactions associated with music entities (artists, albums, songs, lists) or standalone chats without a parent.

## Purpose
- View AI chat history with pagination
- Inspect chat details including messages, parameters, and responses
- Navigate to parent entities (artists, albums, songs, lists)
- Debug and audit AI interactions

## Inheritance
- Inherits from: `Admin::Music::BaseController`
- Uses layout: `music/admin`

## Authorization
Inherits from `Admin::Music::BaseController` which requires admin or editor role via `authenticate_admin!`.

## Scoping

### `MUSIC_PARENT_TYPES` (constant)
Defines which parent types are considered music-related:
- `Music::Artist`
- `Music::Album`
- `Music::Song`
- `Music::Albums::List`
- `Music::Songs::List`

### `music_scoped_ai_chats` (private)
Returns AI chats that either:
- Have a parent_type in `MUSIC_PARENT_TYPES`, OR
- Have no parent (`parent_type: nil`)

This scoping is applied to both index and show actions, ensuring non-music AI chats (e.g., Books::List parent) return 404.

## Actions

### `index`
Lists music-scoped AI chats with pagination.

**Features:**
- Eager loads `parent` and `user` associations to prevent N+1
- Ordered by `created_at DESC` (newest first)
- 25 chats per page via Pagy
- Turbo Frame wrapper for future search enhancements

**Displayed Columns:**
- ID (linked to show)
- Chat Type (badge: general, ranking, recommendation, analysis)
- Provider (badge: openai, anthropic, gemini, local)
- Model (monospace)
- Parent (type label + linked name, or user email, or dash)
- Created At

### `show`
Displays detailed AI chat information organized in cards.

**Basic Information Card:**
- Chat Type (badge)
- Provider (badge)
- Model
- Temperature
- JSON Mode (enabled/disabled)

**JSONB Data Cards (conditionally displayed):**
- Messages - formatted JSON
- Parameters - formatted JSON
- Response Schema - formatted JSON
- Raw Responses - formatted JSON

**Sidebar Cards:**
- Parent (if present): type and linked name
- User (if present): linked email and display name
- Metadata: ID, created_at, updated_at

## Routes

| Verb | Path | Action |
|------|------|--------|
| GET | /admin/ai_chats | index |
| GET | /admin/ai_chats/:id | show |

**Note:** Read-only interface. No create, edit, or destroy actions.

## Views

### Index (`index.html.erb`)
- Page header with title and description
- AI chats table wrapped in Turbo Frame

### Table Partial (`_table.html.erb`)
- Columns: ID, Chat Type, Provider, Model, Parent, Created, Actions
- Chat type badges: general (ghost), ranking (primary), recommendation (secondary), analysis (accent)
- Provider badges: openai (success), anthropic (warning), gemini (info), local (ghost)
- Parent column shows type label and linked name
- Empty state with chat icon

### Show (`show.html.erb`)
- Back button to index
- 3-column grid layout (2 main + 1 sidebar)
- Basic Information card
- Conditional JSONB cards with `<pre><code>` formatting
- Parent/User/Metadata cards in sidebar

## Helper Methods

Uses `Admin::AiChatsHelper` for:
- `admin_ai_chat_parent_path(ai_chat)` - polymorphic admin path for parent
- `ai_chat_parent_display_name(ai_chat)` - display name from parent
- `ai_chat_parent_type_label(ai_chat)` - human-readable type label
- `ai_chat_type_badge_class(chat_type)` - badge class for chat type
- `ai_chat_provider_badge_class(provider)` - badge class for provider

## Related Classes
- `Admin::Music::BaseController` - Parent class with music admin layout
- `AiChat` - Model being displayed
- `Admin::AiChatsHelper` - Helper for parent linking and badge styling
- Pagy - Pagination

## File Location
`app/controllers/admin/music/ai_chats_controller.rb`

## View Files
- `app/views/admin/music/ai_chats/index.html.erb`
- `app/views/admin/music/ai_chats/_table.html.erb`
- `app/views/admin/music/ai_chats/show.html.erb`

## Tests
`test/controllers/admin/music/ai_chats_controller_test.rb` - 16 tests covering:
- Index and show actions
- Empty state handling
- Non-existent chat (404)
- Non-music chat (404)
- Authorization (admin, editor allowed; user denied)
