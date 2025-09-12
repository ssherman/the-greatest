# Image

## Summary
Polymorphic model for image uploads supporting cover art, photos, and visual assets across all media types (albums, artists, releases, etc.). Uses Active Storage for file handling with multiple variants and CDN delivery.

## Associations
- `belongs_to :parent, polymorphic: true` - The entity this image belongs to (Artist, Album, Release, etc.)
- `has_one_attached :file` - Active Storage attachment for the actual image file

## Public Methods

### Active Storage Variants
- `file.variant(:small)` - 100x100 pixel variant for thumbnails
- `file.variant(:medium)` - 150x150 pixel variant for lists
- `file.variant(:large)` - 250x250 pixel variant for detail views

### Metadata Accessors
- `analyzed` - Boolean indicating if image has been analyzed
- `identified` - Boolean indicating if image has been identified
- `analyzed=`, `identified=` - Setters for metadata

## Validations
- `file` - presence required
- `primary` - must be true or false
- `acceptable_image_format` - validates JPEG, PNG, WebP, or GIF content types

## Scopes
- `primary` - Returns only primary images
- `non_primary` - Returns only non-primary images

## Constants
None.

## Callbacks
- `after_save :unset_other_primary_images` - Automatically unsets other primary images when this image is marked as primary

## Database Fields
- `parent_type` (string) - Polymorphic type (e.g., "Music::Artist")
- `parent_id` (bigint) - Polymorphic ID
- `notes` (text) - Optional description or notes about the image
- `metadata` (jsonb) - Structured metadata storage with analyzed/identified accessors
- `primary` (boolean) - Whether this is the primary image for the parent entity
- `created_at`, `updated_at` - Standard timestamps

## Storage Configuration
- **Development**: Uses Cloudflare R2 with `images-dev.thegreatestmusic.org` bucket
- **Production**: Uses Cloudflare R2 with `images.thegreatestmusic.org` bucket
- **CDN**: Direct blob serving via custom routes for optimal performance

## Supported File Types
- JPEG (`image/jpeg`)
- PNG (`image/png`) 
- WebP (`image/webp`)
- GIF (`image/gif`)

## Primary Image Logic
- Only one primary image allowed per parent entity
- Setting `primary: true` automatically unsets other primary images for the same parent
- Uses `update_all` to avoid validation recursion when unsetting other primary images
- No validation prevents multiple primary images - handled automatically via callback

## Dependencies
- Active Storage for file handling
- `image_processing` gem for variants
- `ruby-vips` for image processing
- `aws-sdk-s3` for S3-compatible storage (Cloudflare R2)
- Cloudflare R2 storage service

## Usage Examples

### Accessing primary image
```ruby
artist = Music::Artist.find(1)
primary_image = artist.primary_image
```

### Creating a new primary image
```ruby
image = Image.new(
  parent: artist,
  primary: true,
  notes: "Official artist photo"
)
image.file.attach(uploaded_file)
image.save!
```

### Getting different variants
```ruby
small_url = image.file.variant(:small).url
medium_url = image.file.variant(:medium).url  
large_url = image.file.variant(:large).url
```

## Related Models
- `Music::Artist` - has_many :images, has_one :primary_image
- `Music::Album` - has_many :images, has_one :primary_image  
- `Music::Release` - has_many :images, has_one :primary_image

## Admin Interface
Managed through Avo with fields for:
- File upload with image preview
- Polymorphic parent selection (Artist, Album, Release)
- Primary checkbox with help text
- Notes field for descriptions
- Read-only metadata fields