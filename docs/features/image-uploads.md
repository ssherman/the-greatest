# Image Upload System

## Overview
Comprehensive image upload and management system supporting cover art, photos, and visual assets across all media types in The Greatest platform. Implemented September 2025.

## Core Components

### Models
- **`Image`** - Polymorphic model for all image uploads
- **`Music::Artist`** - Extended with image support
- **`Music::Album`** - Extended with image support  
- **`Music::Release`** - Extended with image support

### Key Features
- **Polymorphic Design** - Single Image model supports all entity types
- **Multiple Images** - Each entity can have multiple images
- **Primary Image** - One designated primary image per entity for ranking views
- **Automatic Variants** - Multiple sizes generated automatically
- **CDN Delivery** - Direct serving via Cloudflare R2 and CDN
- **Admin Interface** - Full CRUD through Avo

## Architecture

### Storage Configuration
- **Service**: Cloudflare R2 (S3-compatible)
- **Development**: `images-dev.thegreatestmusic.org` bucket
- **Production**: `images.thegreatestmusic.org` bucket
- **Processing**: libvips with image_processing gem
- **Delivery**: Direct CDN routes for optimal performance

### Image Variants
- **Small**: 100x100 pixels - For thumbnails and compact lists
- **Medium**: 150x150 pixels - For standard list views
- **Large**: 250x250 pixels - For detail pages and ranking displays

### Database Schema
```sql
CREATE TABLE images (
  id BIGINT PRIMARY KEY,
  parent_type VARCHAR NOT NULL,  -- Polymorphic type
  parent_id BIGINT NOT NULL,     -- Polymorphic ID
  notes TEXT,                    -- Optional description
  metadata JSONB DEFAULT '{}',   -- Structured metadata
  primary BOOLEAN DEFAULT FALSE NOT NULL, -- Primary image flag
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);

CREATE INDEX index_images_on_parent_and_primary 
ON images (parent_type, parent_id, primary);
```

## Primary Image Logic

### Automatic Management
- Setting `primary: true` automatically unsets other primary images for same parent
- Uses `after_save` callback with `update_all` for efficient batch updates
- No validation conflicts - handled entirely through database operations

### Business Rules
- Maximum one primary image per entity (artist, album, release)
- Multiple non-primary images allowed
- Primary images used in ranking views and default displays
- Non-primary images available for galleries and detailed views

## Supported Entity Types

### Music::Artist
- **Use Cases**: Artist photos, promotional images, band shots
- **Primary**: Main artist photo for ranking displays
- **Additional**: Tour photos, historical images, alternate shots

### Music::Album  
- **Use Cases**: Album artwork, alternative covers, concept art
- **Primary**: Main album cover for ranking displays
- **Additional**: Back covers, liner notes, alternate editions

### Music::Release
- **Use Cases**: Format-specific covers, regional variants, remaster artwork
- **Primary**: Main cover for that specific release
- **Additional**: Insert cards, promotional materials, format variants

## File Support

### Supported Formats
- JPEG (`image/jpeg`) - Photos and complex images
- PNG (`image/png`) - Graphics with transparency
- WebP (`image/webp`) - Modern efficient format
- GIF (`image/gif`) - Animated or simple graphics

### Validation
- File presence required
- Content type validation for supported formats
- File size limits enforced by storage service

## Admin Interface

### Image Management
- **Upload Interface**: Drag-and-drop file upload with preview
- **Parent Selection**: Polymorphic dropdown for Artist/Album/Release
- **Primary Toggle**: Checkbox with automatic conflict resolution
- **Notes Field**: Optional description and context
- **Metadata Display**: Read-only technical information

### Entity Integration
- **Images Tab**: All images for each artist/album/release
- **Primary Image Field**: Quick access to current primary image
- **Bulk Operations**: Future enhancement for batch management

## Usage Patterns

### Creating Primary Images
```ruby
# Upload primary artist photo
image = Image.new(parent: artist, primary: true)
image.file.attach(uploaded_file)
image.save! # Automatically unsets other primary images

# Access primary image
artist.primary_image&.file&.variant(:large)&.url
```

### Managing Multiple Images
```ruby
# Add additional images
artist.images.create!(
  primary: false,
  notes: "Concert photo from 2023 tour"
).file.attach(concert_photo)

# Get all images
artist.images.includes(:file_attachment)
```

### Display Different Variants
```ruby
# Different sizes for different contexts
thumbnail = image.file.variant(:small).url
list_view = image.file.variant(:medium).url  
detail_view = image.file.variant(:large).url
```

## Performance Considerations

### CDN Integration
- Direct blob routes bypass Rails for image serving
- Environment-specific CDN URLs for optimal delivery
- Automatic HTTPS with Cloudflare SSL

### Background Processing
- Variant generation happens asynchronously
- Database operations optimized with proper indexing
- Bulk updates use `update_all` to avoid N+1 queries

### Caching Strategy
- Browser caching via CDN headers
- Rails fragment caching includes image URLs
- Database queries optimized with includes

## Future Enhancements

### Planned Features
- **Image Optimization**: Automatic compression and format conversion
- **Metadata Extraction**: EXIF data parsing and storage
- **Bulk Upload**: Multiple file upload interface
- **Image Cropping**: Admin interface for aspect ratio adjustments
- **Format Conversion**: Automatic WebP generation for modern browsers

### Extensibility
- **Additional Entity Types**: Easy to add books, movies, games
- **Custom Variants**: Configurable sizes per entity type
- **Multiple Primaries**: Different primary images for different contexts
- **AI Integration**: Automatic tagging and content recognition

## Security Considerations

### File Validation
- Content type verification beyond file extension
- File size limits to prevent abuse
- Malicious file detection and rejection

### Access Control
- Admin-only upload interface
- Public read access to approved images
- Proper authentication for management operations

## Monitoring and Maintenance

### Key Metrics
- Upload success rates
- Storage usage by entity type
- CDN hit rates and performance
- Primary image coverage across entities

### Maintenance Tasks
- Periodic cleanup of orphaned files
- Storage usage monitoring and alerts
- CDN performance optimization
- Database index performance monitoring

## Related Documentation
- [Image Model](../models/image.md) - Detailed model documentation
- [Music::Artist](../models/music/artist.md) - Artist model with image support
- [Music::Album](../models/music/album.md) - Album model with image support  
- [Music::Release](../models/music/release.md) - Release model with image support
- [TODO: Image Upload Implementation](../todos/037-image-uploads.md) - Implementation details