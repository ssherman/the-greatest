# Admin::Music::AiChatsController

## Summary
Admin controller for viewing AI chat history related to music domain entities. Provides read-only access to AiChats associated with music artists, albums, songs, and music lists.

## Inheritance
Extends `Admin::Music::BaseController` - inherits music domain authorization and layout.

## Actions

### `index`
Displays paginated list of music-related AI chats.

**Response:** Renders index view with `@ai_chats` and `@pagy`
**Includes:** `:parent`, `:user` associations (eager loaded)
**Order:** Most recent first (`created_at: :desc`)
**Pagination:** 25 items per page via Pagy

### `show`
Displays details of a single AI chat.

**Parameters:** `id` - AiChat ID
**Response:** Renders show view with `@ai_chat`
**Error:** Returns 404 if chat not found or not in music scope

## Constants

### `MUSIC_DIRECT_PARENT_TYPES`
Array of non-STI music parent types stored directly in `parent_type`:
- `Music::Artist`
- `Music::Album`
- `Music::Song`

### `MUSIC_LIST_STI_TYPES`
Array of music List STI subclass types (stored in `lists.type`, not `ai_chats.parent_type`):
- `Music::Albums::List`
- `Music::Songs::List`

## Private Methods

### `set_ai_chat`
Before action for `show`. Finds AiChat within music scope.

### `music_scoped_ai_chats`
Returns AiChats within the music domain scope.

**Includes:**
1. AiChats with direct music parent types (`Music::Artist`, `Music::Album`, `Music::Song`)
2. AiChats with music List STI parent types (`Music::Albums::List`, `Music::Songs::List`)
3. AiChats with no parent (`parent_type IS NULL`)

**Excludes:**
- AiChats with non-music parent types (e.g., `Books::List`, `Games::List`)

**Implementation Note:** Uses subquery-based filtering for List STI types because Rails' `.or()` doesn't support mixing JOIN-based and non-JOIN relations. The method creates a subquery with `AiChat.with_list_parent_types(...).select(:id)` to avoid loading IDs into memory and potential SQL size limits.

## Authorization
Inherits from `Admin::Music::BaseController`:
- Requires authenticated user
- Requires admin or editor role
- Scoped to music domain only

## Routes
```
GET  /admin/ai_chats     -> index
GET  /admin/ai_chats/:id -> show
```

## Dependencies
- `AiChat.with_list_parent_types` scope for STI-aware List filtering
- Pagy for pagination
- `Admin::Music::BaseController` for authorization

## Related Documentation
- `docs/models/ai_chat.md` - AiChat model documentation
- `docs/specs/completed/111-ai-chat-parent-type-sti-fix.md` - STI scoping implementation spec
