# Services::Music::AmazonProductService

## Summary
Service class for Amazon Product API integration with Music::Album records. Handles the complete workflow of searching Amazon's music catalog, validating matches with AI, creating external links, and downloading primary images.

## Public Methods

### `self.call(album:)`
Main entry point for Amazon product enrichment
- Parameters:
  - `album` (Music::Album) - Album to enrich with Amazon data
- Returns: Hash with `:success` boolean and `:data` (success message) or `:error` (error message)
- Side Effects: Creates ExternalLink records, downloads and attaches primary images

## Private Methods

### `#search_amazon_products`
Searches Amazon Product API for music products matching the album
- Uses first artist name and album title as search parameters
- Searches Music index for comprehensive coverage (CDs, vinyl, digital)
- Returns: Array of Amazon product hashes or nil on error

### `#validate_matches_with_ai(search_results)`
Uses AI to validate that Amazon products match the target album
- Delegates to `Services::Ai::Tasks::AmazonAlbumMatchTask`
- Returns: Array of validated match hashes with `:asin` keys or nil on error

### `#create_external_links(validated_results, search_results)`
Creates ExternalLink records for validated Amazon products
- Uses `find_or_create_by!` to prevent duplicates
- Stores full Amazon product data in metadata field
- Extracts and stores price information in cents
- Updates existing links with current price/metadata
- Returns: Array of created/updated ExternalLink records

### `#set_primary_image_from_best_product(validated_results, search_results)`
Downloads primary image from highest-ranked Amazon product
- Only sets image if album doesn't already have one
- Sorts products by sales rank (lower number = better ranking)
- Downloads from product with best sales rank that has an image
- Uses Large image size for highest quality

### `#download_and_set_image(image_url)`
Downloads image file and creates Image record
- Uses Down gem for reliable HTTP downloads
- Creates Image with `primary: true`
- Uses build/attach/save pattern to avoid validation errors
- Cleans up temporary files after processing

### `#amazon_client`
Creates and configures Vacuum client for Amazon API
- Requires environment variables: `AMAZON_PRODUCT_API_ACCESS_KEY`, `AMAZON_PRODUCT_API_SECRET_KEY`, `AMAZON_PRODUCT_API_PARTNER_KEY`
- Configured for US marketplace
- Returns nil if credentials not configured

### `#extract_price_cents(product)`
Extracts price information from Amazon product data
- Prefers "New" condition prices over used/refurbished
- Converts dollar amounts to cents for storage
- Returns: Integer price in cents or nil if no price available

## Constants

### `AMAZON_RESOURCES`
Array of Amazon API resource paths to request:
- ItemInfo (title, artist, classifications, content info)
- Images (small, medium, large primary images)
- BrowseNodeInfo (sales ranking)
- Offers (pricing information)

## Validations
- Album must have a title (required for Amazon search)
- Album must have at least one artist (required for Amazon search)
- Amazon API credentials must be configured

## Dependencies
- `Vacuum` gem for Amazon Product API calls
- `Down` gem for image downloads
- `Services::Ai::Tasks::AmazonAlbumMatchTask` for AI validation
- `ExternalLink` model for storing product links
- `Image` model for storing downloaded images

## Error Handling
- Comprehensive error handling for API failures, validation errors, and image download issues
- All errors logged and collected in `@errors` array
- Returns structured failure responses with error details
- Graceful degradation - external link creation continues even if image download fails

## Workflow
1. **Validation**: Check album has title and artists
2. **Search**: Query Amazon Product API with artist/title parameters
3. **AI Validation**: Confirm products match the target album
4. **Link Creation**: Create ExternalLink records for validated products
5. **Image Download**: Set primary image from best-ranked product with image

## Performance Considerations
- Only downloads images for albums without existing primary images
- Uses sales ranking to select highest-quality/most-relevant product images
- Processes validated matches sequentially to avoid overwhelming external services
- Temporary file cleanup prevents disk space issues

## External Integrations
- **Amazon Product API**: Music catalog search and product data
- **AI Service**: Album/product matching validation
- **Image Storage**: Active Storage for downloaded album artwork