# UI Album Rankings Feature

## Overview
The first user-facing UI implementation for The Greatest, providing a responsive interface for browsing ranked music albums. Built with DaisyUI components and optimized for performance and caching.

## Architecture

### Controller Hierarchy
```
RankedItemsController (base)
└── Music::RankedItemsController (music domain)
    └── Music::Albums::RankedItemsController (album-specific)
```

### URL Structure
- `/albums` - Default global album rankings
- `/albums/page/2` - Paginated default rankings  
- `/rc/123/albums` - Specific ranking configuration
- `/rc/123/albums/page/3` - Paginated specific configuration

### Key Components
1. **Controllers**: Inheritance-based hierarchy for extensibility
2. **Views**: DaisyUI-styled responsive grid layout
3. **Helpers**: Custom Pagy URL generation for complex routes
4. **Styles**: Organized CSS with separate pagination styling
5. **Routes**: Rails scope pattern for optional parameters

## Features

### Display Elements
- **Album Cover**: Square aspect ratio images with top-aligned cropping
- **Ranking Badge**: Prominent rank number with primary color
- **Album Info**: Title, artist(s), release year
- **Categories**: Up to 3 category badges with overflow indicator
- **Responsive Grid**: 1-4 columns based on screen size

### Pagination
- **Pagy Integration**: 25 items per page with overflow handling
- **Cache-Friendly URLs**: Explicit `/page/N` format for edge caching
- **JavaScript Support**: Handles Pagy's dynamic pagination placeholders

### Performance Optimizations
- **N+1 Prevention**: Uses `includes` for efficient association loading
- **Query Optimization**: Avoids problematic JOINs that create duplicates
- **Pagination**: Limits database load and enables caching

## Technical Implementation

### Route Configuration
```ruby
scope "(/rc/:ranking_configuration_id)" do
  get "albums", to: "music/albums/ranked_items#index"
  get "albums/page/:page", to: "music/albums/ranked_items#index", 
      constraints: { page: /\d+|__pagy_page__/ }
end
```

### Query Strategy
```ruby
@ranking_configuration.ranked_items
  .joins("JOIN music_albums ON ranked_items.item_id = music_albums.id AND ranked_items.item_type = 'Music::Album'")
  .includes(item: [:artists, :categories, :primary_image])
  .where(item_type: 'Music::Album')
  .order(:rank)
```

### CSS Organization
- **Main CSS**: `music/application.css` with imports and configuration
- **Pagination**: Separate `music/paging.css` file for maintainability
- **DaisyUI**: Component-based styling with Tailwind utilities

## Error Handling
- **404 for Missing Configs**: Proper error responses for invalid ranking configurations
- **Type Validation**: Ensures only album ranking configurations are used
- **Overflow Protection**: Pagy configured to redirect to last page on overflow

## Testing Strategy
- **Controller Tests**: Focus on HTTP response codes, not content
- **Domain Configuration**: Proper host setup for multi-domain testing
- **Route Coverage**: Tests for all URL patterns and edge cases
- **Error Scenarios**: Comprehensive 404 and validation testing

## Extensibility
- **Controller Hierarchy**: Ready for books, movies, games implementations
- **Shared Base Logic**: Common ranking functionality in base controllers
- **CSS Patterns**: Reusable pagination and component styles
- **Route Patterns**: Consistent URL structure across media types

## Future Enhancements
- **View Components**: Extract common UI elements for reuse
- **Advanced Filtering**: Category, year, artist filtering options
- **Detail Pages**: Link to individual album pages
- **Real-time Updates**: Live ranking changes
- **Caching Layer**: Full page caching with invalidation

## Related Documentation
- [RankedItemsController](../controllers/ranked_items_controller.md)
- [Music::Albums::RankedItemsController](../controllers/music/albums/ranked_items_controller.md)
- [RankingConfiguration Model](../models/ranking_configuration.md)
- [RankedItem Model](../models/ranked_item.md)
