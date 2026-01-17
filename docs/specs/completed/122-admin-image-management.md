# 122 - Admin Image Management CRUD Interface

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-01-17
- **Started**: 2026-01-17
- **Completed**: 2026-01-17
- **Developer**: Claude

## Overview
Implement a CRUD admin interface for managing images across polymorphic parent types (Artists, Albums, and future entities like Books, Movies, Games). This includes a base non-type-specific controller, inline image management from parent show pages, primary image toggling, and infrastructure improvements to ensure WebP format support in libvips.

**Scope:**
- Base `Admin::ImagesController` for polymorphic image management
- Inline image CRUD on Artist and Album admin show pages
- Quick-toggle for setting primary image
- Fix WebP support in Docker/libvips configuration
- Single file upload via modal (not batch)

**Non-goals:**
- HEIC/HEIF support (will reject on upload instead)
- Batch/multi-file uploads
- Drag-and-drop image reordering
- Image cropping/editing UI

## Context & Links
- Related tasks/phases: Builds on patterns from `074-custom-admin-phase-3-album-artists.md`
- Source files (authoritative):
  - `app/models/image.rb`
  - `app/controllers/admin/category_items_controller.rb` (pattern reference)
  - `app/views/admin/music/artists/show.html.erb`
  - `app/views/admin/music/albums/show.html.erb`
- External docs:
  - [libvips WebP support](https://github.com/libvips/libvips/wiki/Build-for-Ubuntu)
  - [Active Storage Direct Uploads](https://guides.rubyonrails.org/active_storage_overview.html#direct-uploads)

## Interfaces & Contracts

### Domain Model (diffs only)
No database migrations required. Existing `Image` model already supports:
- Polymorphic `parent` association (Artist, Album, Release, etc.)
- `primary` boolean with automatic conflict resolution
- `notes` text field
- Active Storage `file` attachment with variants

**Validation Enhancement:**
- Add HEIC rejection to `acceptable_image_format` validation
- Keep: JPEG, PNG, WebP, GIF
- Reject: HEIC/HEIF with user-friendly error message

### Endpoints

| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /admin/artists/:artist_id/images | List images for artist (Turbo Frame) | - | admin/editor |
| POST | /admin/artists/:artist_id/images | Create image for artist | image[file], image[notes], image[primary] | admin/editor |
| GET | /admin/albums/:album_id/images | List images for album (Turbo Frame) | - | admin/editor |
| POST | /admin/albums/:album_id/images | Create image for album | image[file], image[notes], image[primary] | admin/editor |
| PATCH | /admin/images/:id | Update image | image[notes], image[primary] | admin/editor |
| DELETE | /admin/images/:id | Delete image | - | admin/editor |
| POST | /admin/images/:id/set_primary | Set as primary image | - | admin/editor |

> Source of truth: `config/routes.rb`

**Routes Pattern** (following shallow nested resources):
```ruby
# Inside music domain constraint
resources :artists do
  resources :images, only: [:index, :create], controller: "/admin/images"
end
resources :albums do
  resources :images, only: [:index, :create], controller: "/admin/images"
end

# Outside namespace (shared controller)
resources :images, only: [:update, :destroy], controller: "admin/images" do
  member do
    post :set_primary
  end
end
```

### Schemas (JSON)

**Create Image Request (multipart/form-data):**
```json
{
  "type": "object",
  "required": ["image[file]"],
  "properties": {
    "image[file]": { "type": "file", "description": "Image file (JPEG, PNG, WebP, GIF)" },
    "image[notes]": { "type": "string", "description": "Optional description" },
    "image[primary]": { "type": "boolean", "description": "Set as primary image" }
  }
}
```

**Turbo Stream Response:**
```json
{
  "type": "array",
  "items": [
    { "action": "replace", "target": "flash" },
    { "action": "replace", "target": "images_list" }
  ]
}
```

### Behaviors (pre/postconditions)

**Preconditions:**
- User must be authenticated as admin or editor
- Parent entity (Artist/Album) must exist
- File must be valid image format (JPEG, PNG, WebP, GIF)
- File size must be reasonable (recommend max 10MB)

**Postconditions/effects:**
- Image record created with Active Storage attachment
- Variants (small, medium, large) preprocessed immediately
- If `primary: true`, other images for same parent automatically set to `primary: false`
- Turbo Stream updates image gallery without page reload

**Edge cases & failure modes:**
- Upload HEIC file → Validation error with message "HEIC format not supported. Please convert to JPEG, PNG, or WebP."
- Delete primary image → No automatic reassignment (user must set new primary)
- Upload very large image (>10MB) → Consider size validation (optional)
- Network failure during upload → Active Storage handles partial uploads gracefully
- Delete parent entity → Images destroyed via `dependent: :destroy`

### Non-Functionals
- **Performance**: Turbo Streams for zero full-page reloads
- **N+1 Prevention**: Eager load `images: { file_attachment: { blob: { variant_records: :image_attachment } } }`
- **Security**: Admin/editor role required, CSRF protection
- **File Storage**: Cloudflare R2 (production), same bucket as existing images
- **Responsiveness**: Mobile-friendly image grid and modals

## Acceptance Criteria

### Infrastructure
- [ ] Dockerfile updated to install `libwebp-dev` for proper WebP support
- [ ] WebP upload and variant generation works correctly (verified manually)
- [ ] HEIC uploads rejected with user-friendly error message

### Controller
- [ ] `Admin::ImagesController` handles polymorphic parent detection
- [ ] Create action attaches file and creates Image record
- [ ] Update action modifies notes and primary status
- [ ] Delete action removes image and Active Storage attachment
- [ ] `set_primary` action sets image as primary (unsets others)
- [ ] All actions return Turbo Stream responses
- [ ] Authorization prevents non-admin/editor access

### Artist Show Page
- [ ] Images section displays in sidebar with gallery grid
- [ ] "Add Image" button opens upload modal
- [ ] Upload modal has file input, notes field, primary checkbox
- [ ] Each image has "Set Primary" toggle button (visible if not already primary)
- [ ] Each image has "Edit" button opening edit modal
- [ ] Each image has "Delete" button with confirmation
- [ ] Primary image badge/indicator shown on primary image
- [ ] Turbo Frame updates gallery without page reload

### Album Show Page
- [ ] Same functionality as Artist show page
- [ ] Context-aware (knows it's album context)

### Validation & Error Handling
- [ ] HEIC files rejected with helpful error message
- [ ] Empty file submission shows validation error
- [ ] Invalid file types rejected with list of valid types
- [ ] Flash messages display on success/failure

### Golden Examples

**Example 1: Upload image to artist**
```text
Input:
  - Navigate to /admin/artists/123
  - Click "Add Image"
  - Select file: "artist-photo.webp"
  - Enter notes: "Official press photo 2025"
  - Check "Set as primary"
  - Click "Upload"

Output:
  - Image appears in gallery grid
  - Primary badge shown on new image
  - Previous primary image (if any) loses primary badge
  - Flash: "Image uploaded successfully."
  - Modal closes automatically
```

**Example 2: Toggle primary image**
```text
Input:
  - On artist show page with 3 images
  - Image #2 is currently primary
  - Click "Set Primary" on Image #3

Output:
  - Image #3 now shows primary badge
  - Image #2 no longer shows primary badge
  - Flash: "Primary image updated."
  - No page reload (Turbo Stream)
```

**Example 3: Reject HEIC upload**
```text
Input:
  - Click "Add Image"
  - Select file: "photo.heic"
  - Click "Upload"

Output:
  - Validation error displayed
  - Flash error: "File must be a JPEG, PNG, WebP, or GIF. HEIC format is not supported."
  - Modal stays open for retry
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture
- Use same Turbo Stream pattern as `category_items_controller.rb`
- Use same modal pattern as album_artists (DaisyUI `<dialog>`)
- Respect snippet budget (≤40 lines)
- Do not duplicate authoritative code; **link to file paths**

### Required Outputs
- Updated files (paths listed in "Key Files Touched")
- Passing tests demonstrating Acceptance Criteria
- Updated: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder → collect comparable patterns (category_items, album_artists)
2) codebase-analyzer → verify Active Storage integration and variant setup
3) web-search-researcher → libvips/libwebp Dockerfile best practices
4) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- Existing fixtures: `test/fixtures/images.yml`, `test/fixtures/music/artists.yml`, `test/fixtures/music/albums.yml`
- Need fixture images for testing upload (small JPEG/PNG/WebP files in `test/fixtures/files/`)

---

## Implementation Notes (living)

### Approach Taken
- Used Rails generator to create `Admin::ImagesController` with test file
- Followed existing polymorphic controller pattern from `Admin::CategoryItemsController`
- Context detection from URL params (`artist_id`, `album_id`)
- Turbo Stream responses for all mutations (create/update/destroy/set_primary)
- Lazy-loaded Turbo Frame for image gallery on show pages
- DaisyUI dialog modals for add/edit forms
- Hover overlay on image cards for action buttons

### Key Files Touched (paths only)

**New Files:**
- `app/controllers/admin/images_controller.rb` - Polymorphic CRUD controller
- `app/views/admin/images/index.html.erb` - Turbo Frame image gallery
- `app/views/admin/images/_image_card.html.erb` - Individual image card with actions
- `app/helpers/admin/images_helper.rb` - Generated helper
- `test/controllers/admin/images_controller_test.rb` - 21 tests covering all actions
- `test/fixtures/files/test_image.png` - Test fixture image

**Modified Files:**
- `config/routes.rb` - Added nested image routes for artists/albums + standalone routes
- `Dockerfile` - Added `libwebp-dev` package for WebP support
- `app/models/image.rb` - Enhanced HEIC rejection with helpful error message
- `app/views/admin/music/artists/show.html.erb` - Replaced static images section with CRUD interface
- `app/views/admin/music/albums/show.html.erb` - Replaced static images section with CRUD interface
- `app/controllers/admin/music/artists_controller.rb` - Enhanced eager loading for images
- `app/controllers/admin/music/albums_controller.rb` - Enhanced eager loading for images

### Technical Design

#### Controller Architecture

```ruby
# app/controllers/admin/images_controller.rb
# reference only - see authoritative code in repo

class Admin::ImagesController < Admin::BaseController
  before_action :set_image, only: [:update, :destroy, :set_primary]
  before_action :set_parent, only: [:index, :create]

  # Context detection from params (artist_id, album_id, etc.)
  # Turbo Stream responses for all mutations
  # Polymorphic parent lookup similar to category_items_controller
end
```

#### View Structure

**Images Section on Show Page:**
```erb
<!-- reference only -->
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <div class="flex justify-between items-center mb-4">
      <h2 class="card-title">Images <span class="badge"><%= @artist.images.count %></span></h2>
      <button class="btn btn-primary btn-sm" onclick="add_image_modal.showModal()">+ Add Image</button>
    </div>

    <%= turbo_frame_tag "images_list", src: admin_artist_images_path(@artist), loading: :lazy do %>
      <span class="loading loading-spinner"></span>
    <% end %>
  </div>
</div>
```

**Image Card Component:**
```erb
<!-- reference only -->
<div class="relative group">
  <%= image_tag image.file.variant(:medium), class: "rounded-lg w-full aspect-square object-cover" %>

  <% if image.primary? %>
    <span class="badge badge-primary absolute top-2 left-2">Primary</span>
  <% end %>

  <div class="absolute bottom-2 right-2 opacity-0 group-hover:opacity-100 transition-opacity">
    <% unless image.primary? %>
      <%= button_to "Set Primary", set_primary_admin_image_path(image),
          method: :post, class: "btn btn-xs btn-primary" %>
    <% end %>
    <button class="btn btn-xs" onclick="edit_image_<%= image.id %>_modal.showModal()">Edit</button>
    <%= button_to "Delete", admin_image_path(image), method: :delete,
        class: "btn btn-xs btn-error", data: { turbo_confirm: "Delete this image?" } %>
  </div>
</div>
```

#### Dockerfile Update

```dockerfile
# reference only - line 19
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips libwebp-dev postgresql-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
```

**Note:** Adding `libwebp-dev` ensures libvips has WebP encoding/decoding support.

#### Model Enhancement

```ruby
# app/models/image.rb - enhance validation message
# reference only

def acceptable_image_format
  return unless file.attached?

  allowed_types = %w[image/jpeg image/png image/webp image/gif]
  unless file.blob.content_type.in?(allowed_types)
    if file.blob.content_type.in?(%w[image/heic image/heif])
      errors.add(:file, "HEIC/HEIF format is not supported. Please convert to JPEG, PNG, or WebP before uploading.")
    else
      errors.add(:file, "must be a JPEG, PNG, WebP, or GIF")
    end
  end
end
```

### Challenges & Resolutions
(To be filled during implementation)

### Deviations From Plan
(To be filled during implementation)

## Acceptance Results
- Date, verifier, artifacts (screenshots/links):

## Future Improvements
- [ ] Drag-and-drop upload (Dropzone.js or similar)
- [ ] Batch multi-file upload
- [ ] Image cropping before upload
- [ ] HEIC auto-conversion (requires libheif in Docker)
- [ ] Image URL import (paste URL to download)
- [ ] Duplicate image detection (perceptual hashing)
- [ ] Image position/ordering within gallery

## Related PRs
- #... (to be created)

## Documentation Updated
- [ ] `docs/models/image.md` - Add admin interface section
- [ ] `docs/documentation.md` - Cross-reference if needed
