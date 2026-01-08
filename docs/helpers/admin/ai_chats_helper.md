# Admin::AiChatsHelper

## Summary
Helper module for rendering AI chat views in the admin interface. Provides polymorphic parent linking and badge color coding for chat types and providers.

## Public Methods

### `admin_ai_chat_parent_path(ai_chat)`
Returns the admin path for an AI chat's parent entity.
- **Parameters**:
  - `ai_chat` (AiChat) - The AI chat record
- **Returns**: String (path) or nil if no path available

**Supported Parent Types**:
- `Music::Artist` → `admin_artist_path`
- `Music::Album` → `admin_album_path`
- `Music::Song` → `admin_song_path`
- `Music::Albums::List` → `admin_albums_list_path`
- `Music::Songs::List` → `admin_songs_list_path`

**Example**:
```erb
<% parent_path = admin_ai_chat_parent_path(@ai_chat) %>
<% if parent_path %>
  <%= link_to ai_chat_parent_display_name(@ai_chat), parent_path, class: "link link-primary" %>
<% end %>
```

### `ai_chat_parent_display_name(ai_chat)`
Returns a display name for the parent entity.
- **Parameters**:
  - `ai_chat` (AiChat) - The AI chat record
- **Returns**: String or nil

**Display Logic**:
- `Music::Artist` → `parent.name`
- `Music::Album`, `Music::Song` → `parent.title`
- `List` subclasses → `parent.name`
- Other → `"#{class_name} ##{id}"`

### `ai_chat_parent_type_label(ai_chat)`
Returns a human-readable label for the parent type.
- **Parameters**:
  - `ai_chat` (AiChat) - The AI chat record
- **Returns**: String or nil

**Labels**:
- `Music::Artist` → "Artist"
- `Music::Album` → "Album"
- `Music::Song` → "Song"
- `Music::Albums::List` → "Albums List"
- `Music::Songs::List` → "Songs List"
- Other List types → "List"
- Fallback → `demodulize` on parent_type

### `ai_chat_type_badge_class(chat_type)`
Returns DaisyUI badge class based on chat type.
- **Parameters**:
  - `chat_type` (String) - The chat type enum value
- **Returns**: String - DaisyUI badge class name

**Color Coding**:
- `general` → `badge-ghost` (gray)
- `ranking` → `badge-primary` (blue)
- `recommendation` → `badge-secondary` (purple)
- `analysis` → `badge-accent` (teal)

**Example**:
```erb
<span class="badge <%= ai_chat_type_badge_class(@ai_chat.chat_type) %> badge-sm">
  <%= @ai_chat.chat_type.humanize %>
</span>
```

### `ai_chat_provider_badge_class(provider)`
Returns DaisyUI badge class based on AI provider.
- **Parameters**:
  - `provider` (String) - The provider enum value
- **Returns**: String - DaisyUI badge class name

**Color Coding**:
- `openai` → `badge-success` (green)
- `anthropic` → `badge-warning` (yellow)
- `gemini` → `badge-info` (blue)
- `local` → `badge-ghost` (gray)

## Usage Context
Used in the AI chats admin views:
- `app/views/admin/music/ai_chats/index.html.erb`
- `app/views/admin/music/ai_chats/_table.html.erb`
- `app/views/admin/music/ai_chats/show.html.erb`

## Related Files
- **Controller**: `app/controllers/admin/music/ai_chats_controller.rb`
- **Model**: `app/models/ai_chat.rb`
- **Views**: `app/views/admin/music/ai_chats/`

## Design Rationale

### Parent Linking
The polymorphic parent association requires type-based path resolution since different parent types have different admin routes. The helper encapsulates this complexity and gracefully handles unsupported parent types by returning nil.

### Badge Color Coding
- **Chat types**: Colors indicate the purpose of the AI interaction, helping admins quickly identify ranking vs. analysis chats
- **Providers**: Colors provide visual distinction between AI providers for debugging and auditing
