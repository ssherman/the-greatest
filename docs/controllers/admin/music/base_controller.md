# Admin::Music::BaseController

## Summary
Base controller for all Music domain admin interfaces. Sets the admin layout specific to the Music domain.

## Purpose
- Sets domain-specific admin layout for all Music admin controllers
- Inherits authentication and authorization from `Admin::BaseController`
- Provides consistent admin experience within Music domain

## Inheritance
- Inherits from: `Admin::BaseController`
- Inherited by: `Admin::Music::ArtistsController`, `Admin::Music::AlbumsController`, etc.

## Layout
Sets layout to `"music/admin"` which loads:
- `/app/views/layouts/music/admin.html.erb`

This follows the multi-domain architecture pattern where each domain has its own admin layout.

## Why Domain-Specific Layouts

### Benefits
1. **Domain-specific navigation** - Music admin sidebar shows music-specific resources
2. **Branding consistency** - Can use domain-specific colors, logos, styling
3. **Independent evolution** - Music admin can change without affecting Books/Movies admin
4. **Asset optimization** - Load only music-specific JavaScript/CSS bundles

### Multi-Domain Pattern
```
layouts/
├── music/
│   ├── admin.html.erb        # Music admin layout
│   └── application.html.erb  # Music public layout
├── movies/
│   ├── admin.html.erb        # Movies admin layout
│   └── application.html.erb  # Movies public layout
└── books/
    ├── admin.html.erb        # Books admin layout
    └── application.html.erb  # Books public layout
```

## Inheritance Chain
```
ApplicationController
  └── Admin::BaseController
      └── Admin::Music::BaseController (this class)
          ├── Admin::Music::ArtistsController
          ├── Admin::Music::AlbumsController
          ├── Admin::Music::SongsController
          └── Admin::Music::DashboardController
```

## Usage Example

```ruby
class Admin::Music::ArtistsController < Admin::Music::BaseController
  # Automatically uses layouts/music/admin.html.erb
  # Inherits authentication from Admin::BaseController
  # Has access to all admin helpers

  def index
    @artists = Music::Artist.all
  end
end
```

## Domain-Specific Features

### Can Add Music-Specific Helpers
```ruby
class Admin::Music::BaseController < Admin::BaseController
  layout "music/admin"

  helper_method :music_dashboard_stats

  private

  def music_dashboard_stats
    # Music-specific stats for admin sidebar
    {
      artists_count: Music::Artist.count,
      albums_count: Music::Album.count,
      songs_count: Music::Song.count
    }
  end
end
```

### Can Add Music-Specific Before Actions
```ruby
class Admin::Music::BaseController < Admin::BaseController
  layout "music/admin"

  before_action :load_music_navigation_data

  private

  def load_music_navigation_data
    @recent_artists = Music::Artist.order(updated_at: :desc).limit(5)
  end
end
```

## Related Classes
- `Admin::BaseController` - Parent class with authentication
- `Admin::Music::ArtistsController` - Example child controller
- `ApplicationController` - Root controller with domain detection

## Related Views
- `/app/views/layouts/music/admin.html.erb` - Music admin layout
- `/app/views/admin/shared/_sidebar.html.erb` - Shared sidebar partial
- `/app/views/admin/shared/_navbar.html.erb` - Shared navbar partial

## File Location
`/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/base_controller.rb`
