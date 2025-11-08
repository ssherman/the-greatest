# 073 - Custom Admin Interface - Phase 1: Music Artists

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-11-05
- **Started**:
- **Completed**:
- **Developer**:

## Overview
Replace Avo admin interface with a custom Rails admin built on ViewComponents + Hotwire (Turbo + Stimulus), starting with Music::Artist CRUD and the foundation admin UI layout. This phase establishes the base architecture that all future admin resources will follow.

## Context
- **Current Problem**: Avo Pro license costs $600/year and is required for searchable associations with large datasets
- **Scale Issue**: With 4 domains (Music, Movies, Books, Games), this would cost $2,400/year
- **Alternative**: Build custom admin using existing stack (Tailwind, DaisyUI, ViewComponents, Hotwire)
- **Coexistence**: New admin at `/admin`, Avo moved to `/avo` during transition

## Requirements

### Base Admin Infrastructure
- [x] Route namespace for `/admin` path
- [x] Base admin controller with authentication (admin/editor roles only)
- [x] Base admin layout with sidebar navigation
- [x] Authorization system (no Devise - use existing Firebase auth + roles)
- [x] Flash message handling (success, error, warning)
- [x] Responsive design using Tailwind + DaisyUI

### Music::Artist CRUD
- [x] Index page with table view
  - [x] Display: ID, Name, Kind, Country, Albums count, Created at
  - [x] Search/filter by name (PostgreSQL text search)
  - [x] Pagination (Pagy gem)
  - [x] Bulk selection UI
  - [x] Sort by columns (name, kind, created_at)
- [x] Show page
  - [x] All artist fields displayed
  - [x] Associations displayed (albums, categories, identifiers, images, credits)
  - [x] Primary image display
  - [x] External links
  - [x] Action buttons
- [x] New/Create
  - [x] Form with all editable fields
  - [x] Kind enum select
  - [x] Country select
  - [x] Date pickers
  - [x] Validation error display
- [x] Edit/Update
  - [x] Same form as New
  - [x] Pre-populated values
- [x] Destroy
  - [x] Confirmation dialog (Turbo Frame)
  - [x] Dependent records handling

### Admin Actions System
- [x] Base action class (custom, not ActiveInteraction)
- [x] Action registration system
- [x] Three artist actions replicated:
  1. **Generate AI Description** (bulk action)
  2. **Refresh Artist Ranking** (single record action)
  3. **Refresh All Artists Rankings** (index-level action)
- [x] Action execution via Turbo Stream responses
- [x] Background job integration (Sidekiq)
- [x] Success/error/warning flash messages
- [x] Authorization checks per action

### Search Foundation
- [x] OpenSearch integration for artist search (already implemented)
- [x] Search component (ViewComponent + Stimulus)
- [x] Debounced search input (300ms)
- [x] Uses existing Search::Music::Search::ArtistGeneral
- [x] Note: Autocomplete for associations deferred to Phase 2 (not needed for artist CRUD)

## Technical Approach

### 1. Routing & Controllers

```ruby
# config/routes.rb

# Move Avo to /avo
mount_avo at: :avo # Change from default /admin

# New custom admin
namespace :admin do
  root to: "dashboard#index"

  namespace :music do
    resources :artists do
      member do
        post :execute_action # For single-record actions
      end
      collection do
        post :bulk_action # For bulk actions
        post :index_action # For index-level actions
        get :search # For autocomplete
      end
    end
  end
end
```

### 2. Controller Architecture

```ruby
# app/controllers/admin/base_controller.rb
class Admin::BaseController < ApplicationController
  before_action :authenticate_admin!
  layout "admin"

  private

  def authenticate_admin!
    unless current_user&.admin? || current_user&.editor?
      redirect_to root_path, alert: "Access denied. Admin or editor role required."
    end
  end

  def current_user
    @current_user ||= User.find_by(id: session[:user_id]) if session[:user_id].present?
  end
  helper_method :current_user
end

# app/controllers/admin/music/artists_controller.rb
class Admin::Music::ArtistsController < Admin::BaseController
  before_action :set_artist, only: [:show, :edit, :update, :destroy, :execute_action]

  def index
    if params[:q].present?
      # Use OpenSearch for search
      search_results = ::Search::Music::Search::ArtistGeneral.call(params[:q], size: 1000)
      artist_ids = search_results.map { |r| r[:id].to_i }

      # Preserve search order using Rails 7+ in_order_of
      @artists = Music::Artist
        .includes(:categories, :primary_image)
        .in_order_of(:id, artist_ids)

      @pagy, @artists = pagy(@artists, items: 25)
    else
      # Normal database query for browsing
      @artists = Music::Artist.all.includes(:categories, :primary_image)
      @artists = @artists.order(params[:sort] || :name)
      @pagy, @artists = pagy(@artists, items: 25)
    end
  end

  def show
    # @artist loaded by before_action
  end

  def new
    @artist = Music::Artist.new
  end

  def create
    @artist = Music::Artist.new(artist_params)

    if @artist.save
      redirect_to admin_music_artist_path(@artist), notice: "Artist created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    # @artist loaded by before_action
  end

  def update
    if @artist.update(artist_params)
      redirect_to admin_music_artist_path(@artist), notice: "Artist updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @artist.destroy!
    redirect_to admin_music_artists_path, notice: "Artist deleted successfully."
  end

  def execute_action
    action_class = "Admin::Actions::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: [@artist])

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "flash",
          partial: "admin/shared/flash",
          locals: { result: result }
        )
      end
      format.html { redirect_to admin_music_artist_path(@artist), notice: result.message }
    end
  end

  def bulk_action
    artist_ids = params[:artist_ids] || []
    artists = Music::Artist.where(id: artist_ids)

    action_class = "Admin::Actions::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: artists)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("flash", partial: "admin/shared/flash", locals: { result: result }),
          turbo_stream.replace("artists_table", partial: "admin/music/artists/table", locals: { artists: @artists })
        ]
      end
      format.html { redirect_to admin_music_artists_path, notice: result.message }
    end
  end

  def index_action
    action_class = "Admin::Actions::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: [])

    redirect_to admin_music_artists_path, notice: result.message
  end

  def search
    # Use existing OpenSearch implementation
    search_results = ::Search::Music::Search::ArtistGeneral.call(params[:q], size: 10)
    artist_ids = search_results.map { |r| r[:id].to_i }

    # Load artist records preserving search order
    artists = Music::Artist.in_order_of(:id, artist_ids)

    render json: artists.map { |a| { value: a.id, text: a.name } }
  end

  private

  def set_artist
    @artist = Music::Artist.find(params[:id])
  end

  def artist_params
    params.require(:music_artist).permit(
      :name, :description, :kind, :born_on, :year_died,
      :year_formed, :year_disbanded, :country
    )
  end
end
```

### 3. Base Action System

```ruby
# app/actions/admin/base_action.rb
module Admin
  class BaseAction
    attr_reader :user, :models, :fields

    class ActionResult
      attr_reader :status, :message, :data

      def initialize(status:, message:, data: nil)
        @status = status
        @message = message
        @data = data
      end

      def success?
        status == :success
      end

      def error?
        status == :error
      end

      def warning?
        status == :warning
      end
    end

    def self.call(user:, models:, fields: {})
      new(user: user, models: models, fields: fields).call
    end

    def initialize(user:, models:, fields: {})
      @user = user
      @models = Array(models)
      @fields = fields
    end

    def call
      raise NotImplementedError, "Subclasses must implement #call"
    end

    # Override in subclasses to define action metadata
    def self.name
      raise NotImplementedError
    end

    def self.message
      ""
    end

    def self.confirm_button_label
      "Confirm"
    end

    def self.visible?(context = {})
      true
    end

    protected

    def succeed(message, data: nil)
      ActionResult.new(status: :success, message: message, data: data)
    end

    def error(message, data: nil)
      ActionResult.new(status: :error, message: message, data: data)
    end

    def warn(message, data: nil)
      ActionResult.new(status: :warning, message: message, data: data)
    end
  end
end
```

### 4. Artist Actions

```ruby
# app/actions/admin/music/generate_artist_description.rb
module Admin
  module Actions
    module Music
      class GenerateArtistDescription < Admin::BaseAction
        def self.name
          "Generate AI Description"
        end

        def self.message
          "This will generate AI descriptions for the selected artist(s) in the background."
        end

        def self.confirm_button_label
          "Generate Descriptions"
        end

        def call
          artist_ids = models.map(&:id)

          artist_ids.each do |artist_id|
            ::Music::ArtistDescriptionJob.perform_async(artist_id)
          end

          succeed "#{artist_ids.length} artist(s) queued for AI description generation."
        end
      end
    end
  end
end

# app/actions/admin/music/refresh_artist_ranking.rb
module Admin
  module Actions
    module Music
      class RefreshArtistRanking < Admin::BaseAction
        def self.name
          "Refresh Artist Ranking"
        end

        def self.message
          "This will recalculate this artist's ranking based on their albums and songs."
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def call
          return error("This action can only be performed on a single artist.") if models.count > 1

          artist = models.first
          ::Music::CalculateArtistRankingJob.perform_async(artist.id)

          succeed "Artist ranking calculation queued for #{artist.name}."
        end
      end
    end
  end
end

# app/actions/admin/music/refresh_all_artists_rankings.rb
module Admin
  module Actions
    module Music
      class RefreshAllArtistsRankings < Admin::BaseAction
        def self.name
          "Refresh All Artists Rankings"
        end

        def self.message
          "This will recalculate rankings for ALL artists in the system."
        end

        def self.visible?(context = {})
          context[:view] == :index
        end

        def call
          ::Music::CalculateAllArtistsRankingsJob.perform_async

          succeed "All artist rankings queued for recalculation."
        end
      end
    end
  end
end
```

### 5. Layout & Navigation

```erb
<!-- app/views/layouts/admin.html.erb -->
<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <title><%= content_for?(:title) ? yield(:title) : "Admin" %> - The Greatest</title>
  <%= csrf_meta_tags %>
  <%= csp_meta_tag %>
  <%= stylesheet_link_tag "application", "data-turbo-track": "reload" %>
  <%= javascript_importmap_tags %>
</head>
<body class="bg-base-200">
  <div class="drawer lg:drawer-open">
    <input id="admin-drawer" type="checkbox" class="drawer-toggle" />

    <!-- Main content -->
    <div class="drawer-content flex flex-col">
      <!-- Top navbar -->
      <%= render "admin/shared/navbar" %>

      <!-- Flash messages -->
      <div id="flash" class="mx-4 mt-4">
        <%= render "admin/shared/flash" if flash.any? %>
      </div>

      <!-- Page content -->
      <main class="flex-1 p-6">
        <%= yield %>
      </main>
    </div>

    <!-- Sidebar -->
    <div class="drawer-side z-40">
      <label for="admin-drawer" class="drawer-overlay"></label>
      <%= render "admin/shared/sidebar" %>
    </div>
  </div>
</body>
</html>
```

```erb
<!-- app/views/admin/shared/_sidebar.html.erb -->
<aside class="bg-base-100 text-base-content min-h-screen w-80">
  <div class="sticky top-0">
    <!-- Logo/Title -->
    <div class="flex items-center gap-2 px-4 py-6">
      <h1 class="text-2xl font-bold">The Greatest Admin</h1>
    </div>

    <!-- Navigation -->
    <ul class="menu px-4">
      <li><%= link_to "Dashboard", admin_root_path, class: "flex items-center gap-2" %></li>

      <!-- Music Section -->
      <li>
        <details open>
          <summary class="font-semibold">Music</summary>
          <ul>
            <li><%= link_to "Artists", admin_music_artists_path %></li>
            <li><%= link_to "Albums", "#", class: "text-base-content/50" %></li>
            <li><%= link_to "Songs", "#", class: "text-base-content/50" %></li>
            <li><%= link_to "Categories", "#", class: "text-base-content/50" %></li>
          </ul>
        </details>
      </li>

      <!-- Global Section -->
      <li>
        <details>
          <summary class="font-semibold">Global</summary>
          <ul>
            <li><%= link_to "Penalties", "#", class: "text-base-content/50" %></li>
            <li><%= link_to "Users", "#", class: "text-base-content/50" %></li>
          </ul>
        </details>
      </li>
    </ul>

    <!-- User info -->
    <div class="absolute bottom-0 left-0 right-0 border-t border-base-300 p-4">
      <div class="flex items-center gap-2">
        <div class="avatar placeholder">
          <div class="bg-neutral text-neutral-content rounded-full w-10">
            <span><%= current_user.name.first %></span>
          </div>
        </div>
        <div class="flex-1 overflow-hidden">
          <div class="font-medium truncate"><%= current_user.name %></div>
          <div class="badge badge-sm"><%= current_user.role %></div>
        </div>
      </div>
    </div>
  </div>
</aside>
```

### 6. ViewComponents

```ruby
# app/components/admin/search_component.rb
class Admin::SearchComponent < ViewComponent::Base
  def initialize(url:, placeholder: "Search...", param: "q", value: nil)
    @url = url
    @placeholder = placeholder
    @param = param
    @value = value
  end
end

# app/components/admin/search_component.html.erb
<div data-controller="search" data-search-url-value="<%= @url %>">
  <%= form_with url: @url, method: :get, data: { turbo_frame: "search_results", search_target: "form" } do |f| %>
    <%= f.text_field @param,
        value: @value,
        placeholder: @placeholder,
        class: "input input-bordered w-full",
        data: {
          action: "input->search#debounce",
          search_target: "input"
        } %>
  <% end %>
</div>

# app/javascript/controllers/search_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "form"]
  static values = { url: String, debounce: { type: Number, default: 300 } }

  connect() {
    this.timeout = null
  }

  debounce(event) {
    clearTimeout(this.timeout)

    this.timeout = setTimeout(() => {
      this.formTarget.requestSubmit()
    }, this.debounceValue)
  }
}
```

### 7. Search Implementation

**Note**: Artists are already indexed in OpenSearch. The existing search infrastructure will be used:

```ruby
# Existing search service (no changes needed)
# /web-app/app/lib/search/music/search/artist_general.rb

# Already handles:
# - Name normalization (lowercasing, quote normalization)
# - Match phrase queries (exact phrase, boost: 10.0)
# - Match queries with operator:and (all words, boost: 5.0)
# - Keyword exact match (boost: 8.0)
# - Returns array of hashes with :id, :score, :source

# Usage in controller:
search_results = ::Search::Music::Search::ArtistGeneral.call(
  "Beatles",
  size: 10,         # Number of results
  min_score: 1,     # Minimum relevance score
  from: 0           # Offset for pagination
)

# Returns: [{ id: "123", score: 15.2, source: { name: "The Beatles", ... } }]
```

```ruby
# Gemfile additions needed
gem 'pagy'  # Lightweight pagination
```

## Dependencies
- **Existing**: Tailwind CSS, DaisyUI, ViewComponents, Hotwire (Turbo + Stimulus), OpenSearch
- **Add**:
  - `pagy` gem for pagination (lightweight, fast)
- **Firebase Auth**: Already implemented, no changes needed
- **User Roles**: Already implemented (admin, editor, user)
- **OpenSearch**: Already running with Music::Artist indexed

## Acceptance Criteria
- [ ] `/admin` path accessible only to admin/editor users
- [ ] Avo moved to `/avo` path and still functional
- [ ] Admin layout with sidebar navigation renders correctly
- [ ] Music::Artist index page shows artists with search, sort, pagination
- [ ] Music::Artist show page displays all fields and associations
- [ ] Music::Artist new/create/edit/update/destroy CRUD operations work
- [ ] All three artist actions execute successfully via Turbo Stream
- [ ] Flash messages display correctly for success/error/warning
- [ ] Search is debounced and returns results within 300ms
- [ ] Bulk selection UI allows selecting multiple artists
- [ ] Action buttons are visible based on context (index vs show)
- [ ] Authorization prevents non-admin/editor access
- [ ] All pages are responsive (mobile, tablet, desktop)
- [ ] No Avo dependencies in new admin code

## Design Decisions

### Why Custom Over Avo/ActiveAdmin
- **Cost**: Saves $600/year (potentially $2,400/year across domains)
- **Control**: Full control over UX optimized for ranking system
- **Stack Alignment**: Uses existing stack (no new dependencies beyond search/pagination)
- **Learning**: No DSL to learn, pure Rails conventions
- **Performance**: Can optimize specifically for our data patterns

### Why This Action Pattern
- **Avo-Compatible**: Similar interface to Avo actions for easy mental model
- **Simple**: No heavy framework like ActiveInteraction (not well maintained)
- **Testable**: Easy to unit test action classes
- **Flexible**: Can add fields, authorization, validations as needed
- **Turbo-Native**: Built for Hotwire from the start

### Why OpenSearch Over pg_search
- **Already Running**: OpenSearch cluster already in production
- **Already Indexed**: Music::Artist already has search implementation
- **Consistent**: Same search behavior as public site
- **Proven**: Handles 2,000+ artists efficiently with existing boost/scoring
- **No New Dependencies**: Uses existing Search::Music::Search::ArtistGeneral service
- **Future Ready**: Autocomplete can be added in Phase 2 with prefix/completion queries

### Why Pagy Over Kaminari/WillPaginate
- **Performance**: Fastest pagination gem in Ruby ecosystem
- **Lightweight**: Minimal memory footprint
- **Modern**: Built for Hotwire/Turbo
- **Flexible**: Easy to customize markup for DaisyUI

### Sidebar Navigation Pattern
- **DaisyUI Drawer**: Leverages existing component library
- **Collapsible Sections**: Music, Movies, Books, Games, Global
- **Responsive**: Mobile drawer, desktop always visible
- **Sticky User Info**: Shows current user and role at bottom

---

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Phase 1 Implementation Steps

1. **Setup Routes & Base Controller** (Day 1)
   - Move Avo to `/avo`
   - Create admin namespace
   - Create Admin::BaseController with auth

2. **Build Base Layout** (Day 1-2)
   - Admin layout with drawer
   - Sidebar navigation component
   - Flash message component
   - Navbar component

3. **Implement Music::Artist CRUD** (Day 2-3)
   - Controller with all actions
   - Index view with table
   - Show view with associations
   - Form partial for new/edit
   - Add pg_search and pagy gems

4. **Build Action System** (Day 3-4)
   - Base action class
   - ActionResult class
   - Three artist actions
   - Action execution endpoints
   - Turbo Stream responses

5. **Add Search & Pagination** (Day 4)
   - SearchComponent
   - Stimulus search controller
   - Pagination component
   - Search results partial

6. **Testing & Refinement** (Day 5)
   - Manual testing of all CRUD operations
   - Test all three actions
   - Test authorization
   - Mobile responsiveness check
   - Cross-browser testing

### Approach Taken
*[To be filled during implementation]*

### Key Files Created
*[To be filled during implementation]*

### Challenges Encountered
*[To be filled during implementation]*

### Deviations from Plan
*[To be filled during implementation]*

### Testing Approach
*[To be filled during implementation]*

### Performance Considerations
- **OpenSearch**: Already optimized with folding analyzer, keyword subfields
- **Eager Loading**: Use `includes` for associations on show pages (categories, primary_image)
- **Search Result Ordering**: Uses Rails 7+ `in_order_of` (generates `ORDER BY CASE` SQL)
  - Clean, maintainable Rails-native approach
  - If performance issues arise with 200+ results, can optimize to PostgreSQL `unnest WITH ORDINALITY`
- **Pagination**: 25 items per page default (configurable)
- **Search Debounce**: 300ms to reduce query load
- **Turbo Frames**: Minimize full page reloads
- **Batch Size**: Fetch up to 1000 results for search, paginate with standard pagy

### Future Improvements
- [ ] Inline editing for simple fields
- [ ] Advanced filters (by kind, country, date ranges)
- [ ] Export to CSV/JSON
- [ ] Keyboard shortcuts (Cmd+K for search)
- [ ] Recent items sidebar
- [ ] Activity log

### Lessons Learned
*[To be filled during implementation]*

### Related PRs
*[To be filled during implementation]*

### Documentation Updated
- [ ] Class documentation for Admin::BaseController
- [ ] Class documentation for Admin::BaseAction
- [ ] README updated with admin access instructions
- [ ] Component documentation for SearchComponent

## Next Phases

### Phase 2: Music Albums, Songs, Related Models (TODO #074)
- Admin::Music::AlbumsController
- Admin::Music::SongsController
- Admin::Music::CategoriesController
- Admin::Music::ReleasesController
- Admin::Music::TracksController
- Autocomplete for artist/album/song associations (OpenSearch + Slim-Select)
  - Use existing Search::Music::Search::ArtistGeneral
  - Use existing Search::Music::Search::SongGeneral
  - Use existing Search::Music::Search::AlbumGeneral

### Phase 3: Music Join Tables & Rankings (TODO #075)
- Admin::Music::SongArtistsController (with autocomplete!)
- Admin::Music::AlbumArtistsController
- Admin::Music::CreditsController
- Admin::Music::ArtistsRankingConfigurationsController
- Admin::Music::AlbumsRankingConfigurationsController
- Admin::Music::SongsRankingConfigurationsController

### Phase 4: Global Resources (TODO #076)
- Admin::PenaltiesController
- Admin::UsersController
- Admin::RankingConfigurationsController

### Phase 5: Movies, Books, Games (TODO #077-079)
- Replicate Music pattern for other domains
- Domain-specific actions

### Phase 6: Avo Removal (TODO #080)
- Remove Avo gem
- Clean up Avo routes/initializers
- Remove all Avo resource/action files
- Update documentation

## Research References

### Authorization Research (2024-2025)
- **Pundit** recommended (most actively maintained, Rails 8 compatible)
- **Decision**: Using existing Firebase auth + role enums (simpler, no new dependencies)
- User model already has `admin?`, `editor?`, `user?` role methods
- No need for Pundit/CanCanCan for simple role-based access

### Service Object Research
- **ActiveInteraction** is actively maintained (v5.5.0, Feb 2025)
- **Decision**: Custom action pattern (simpler, fewer dependencies, Avo-compatible)
- Using Sidekiq jobs for async operations (already in use)

### Search Research
- **Decision**: Use existing OpenSearch infrastructure
- Search services already implemented:
  - `Search::Music::Search::ArtistGeneral` - Artist name search
  - `Search::Music::Search::SongGeneral` - Song title + artist search
  - `Search::Music::Search::AlbumGeneral` - Album title + artist search
- All use consistent boost values (phrase: 10.0, keyword: 8-9.0, match: 5-8.0)
- Models already indexed with SearchIndexable concern + async Sidekiq job
- Autocomplete pattern (Phase 2): OpenSearch prefix queries + Slim-Select
- **Slim-Select** for autocomplete UI (vanilla JS, Rails 8 compatible)

### Admin UI Research
- **Trestle** - Modern option with Hotwire, but still a framework
- **Administrate** - Rails 8 support coming, but still a framework
- **Decision**: Custom build gives most control and uses existing stack

## Additional Resources
- [DaisyUI Drawer Component](https://daisyui.com/components/drawer/) - Sidebar pattern
- [OpenSearch Ruby Client](https://github.com/opensearch-project/opensearch-ruby) - Client documentation
- [Pagy Documentation](https://github.com/ddnexus/pagy) - Pagination
- [Hotwire Handbook](https://hotwired.dev/) - Turbo + Stimulus patterns
- [ViewComponent Guide](https://viewcomponent.org/) - Component architecture
- [Slim-Select](https://slimselectjs.com/) - Autocomplete library (Phase 2)
