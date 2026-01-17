# Admin::ImagesController

## Summary
Polymorphic controller for managing images across different parent entity types (Artists, Albums, and future entities). Provides CRUD operations with Turbo Stream responses for seamless inline editing from parent show pages.

## Inheritance
`Admin::ImagesController < Admin::BaseController`

## Routes

### Nested Routes (within music domain)
| Verb | Path | Action | Purpose |
|------|------|--------|---------|
| GET | `/admin/artists/:artist_id/images` | index | List images for artist |
| POST | `/admin/artists/:artist_id/images` | create | Upload image for artist |
| GET | `/admin/albums/:album_id/images` | index | List images for album |
| POST | `/admin/albums/:album_id/images` | create | Upload image for album |

### Standalone Routes (global admin namespace)
| Verb | Path | Action | Purpose |
|------|------|--------|---------|
| PATCH | `/admin/images/:id` | update | Update image notes/primary |
| DELETE | `/admin/images/:id` | destroy | Delete image |
| POST | `/admin/images/:id/set_primary` | set_primary | Set image as primary |

## Actions

### `index`
Lists images for a parent entity (Artist or Album).
- **Response**: Rendered without layout for Turbo Frame
- **View**: `admin/images/index.html.erb`
- **Eager Loading**: `file_attachment: :blob`

### `create`
Creates a new image attached to a parent entity.
- **Parameters**: `image[file]`, `image[notes]`, `image[primary]`
- **Response**: Turbo Stream replacing flash and images_list, or HTML redirect
- **Validation**: File presence, acceptable format (JPEG, PNG, WebP, GIF)

### `update`
Updates image notes and/or primary status.
- **Parameters**: `image[notes]`, `image[primary]`
- **Note**: File cannot be updated (only notes and primary)
- **Response**: Turbo Stream or HTML redirect

### `destroy`
Deletes an image and its Active Storage attachment.
- **Response**: Turbo Stream or HTML redirect
- **Cascade**: Active Storage blob purged automatically

### `set_primary`
Sets an image as the primary image for its parent.
- **Side Effect**: Automatically unsets other primary images (via model callback)
- **Response**: Turbo Stream or HTML redirect

## Before Actions
- `set_parent` (index, create) - Detects parent from `artist_id` or `album_id` params
- `set_image` (update, destroy, set_primary) - Loads image by ID

## Private Methods

### `set_parent`
Detects parent entity type from URL parameters:
```ruby
@parent = if params[:artist_id]
  Music::Artist.find(params[:artist_id])
elsif params[:album_id]
  Music::Album.find(params[:album_id])
end
```

### `redirect_path_for_parent(parent)`
Returns appropriate admin show path based on parent type:
- `Music::Artist` → `admin_artist_path(parent)`
- `Music::Album` → `admin_album_path(parent)`

## Turbo Stream Responses
All mutation actions return Turbo Stream responses with:
1. `turbo_stream.replace("flash", ...)` - Update flash messages
2. `turbo_stream.replace("images_list", ...)` - Refresh image gallery

## Views

### `index.html.erb`
Turbo Frame wrapper containing grid of image cards:
- Uses `turbo_frame_tag "images_list"`
- Renders `_image_card` partial for each image
- Shows empty state message when no images

### `_image_card.html.erb`
Individual image display with:
- Image thumbnail using `:medium` variant
- Primary badge indicator
- Hover overlay with action buttons:
  - Set Primary (if not already primary)
  - Edit (opens modal)
  - Delete (with confirmation)
- Inline edit modal with notes and primary fields

## Authorization
- Requires admin or editor role (inherited from `Admin::BaseController`)
- Uses `authenticate_admin!` before action

## Usage in Parent Show Pages

### Artist Show Page
```erb
<%= turbo_frame_tag "images_list", loading: :lazy,
    src: admin_artist_images_path(@artist) do %>
  <span class="loading loading-spinner"></span>
<% end %>
```

### Add Image Modal
```erb
<%= form_with model: Image.new,
              url: admin_artist_images_path(@artist),
              data: { controller: "modal-form" } do |f| %>
  <%= f.file_field :file %>
  <%= f.text_area :notes %>
  <%= f.check_box :primary %>
<% end %>
```

## Dependencies
- `Admin::BaseController` - Authentication and authorization
- `Image` model - Polymorphic image storage
- `modal-form` Stimulus controller - Auto-close modals on success
- Active Storage - File uploads and variants

## Related Files
- `app/models/image.rb` - Image model
- `app/views/admin/images/` - View templates
- `app/views/admin/music/artists/show.html.erb` - Artist integration
- `app/views/admin/music/albums/show.html.erb` - Album integration
- `config/routes.rb` - Route definitions
