# Admin::SearchComponent

## Summary
Reusable ViewComponent that renders a search input with debounced live search functionality. Uses DaisyUI styling and Stimulus controller for interactive behavior.

## Purpose
- Provide consistent search UI across admin interfaces
- Debounce user input to prevent excessive requests
- Support Turbo Frame partial page updates
- Integrate with OpenSearch endpoints for live results

## Component Type
**ViewComponent** - Reusable UI component with Ruby class + ERB template

## File Locations
- **Class**: `/home/shane/dev/the-greatest/web-app/app/components/admin/search_component.rb`
- **Template**: `/home/shane/dev/the-greatest/web-app/app/components/admin/search_component/search_component.html.erb`
- **Stimulus Controller**: `/home/shane/dev/the-greatest/web-app/app/javascript/controllers/admin/search_controller.js`
- **CSS**: Uses DaisyUI utility classes

## Component Class

### Initialization Parameters

```ruby
def initialize(url:, turbo_frame:, param: "q", value: nil, placeholder: "Search...")
  @url = url
  @turbo_frame = turbo_frame
  @param = param
  @value = value
  @placeholder = placeholder
end
```

**Parameters:**
- `url:` (String, required) - The search endpoint URL
- `turbo_frame:` (String, required) - ID of Turbo Frame to update with results
- `param:` (String, optional) - Query parameter name (default: `"q"`)
- `value:` (String, optional) - Initial search value (default: `nil`)
- `placeholder:` (String, optional) - Input placeholder text (default: `"Search..."`)

**Attributes:**
- `@url` - Search endpoint URL
- `@turbo_frame` - Turbo Frame target ID
- `@param` - Query param name
- `@value` - Current search value
- `@placeholder` - Placeholder text

## Template Structure

### HTML/ERB Template
```erb
<div data-controller="admin--search"
     data-admin--search-url-value="<%= url %>"
     data-admin--search-debounce-value="300">
  <%= form_with url: url, method: :get, data: { turbo_frame: turbo_frame, admin__search_target: "form" } do %>
    <label class="input input-bordered flex items-center gap-2">
      <%= text_field_tag param, value,
          placeholder: placeholder,
          class: "grow",
          autocomplete: "off",
          data: {
            admin__search_target: "input",
            action: "input->admin--search#search"
          } %>
      <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5 opacity-70" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
      </svg>
    </label>
  <% end %>
</div>
```

### Key Elements
1. **Stimulus Controller** - `data-controller="admin--search"` for interactive behavior
2. **Turbo Form** - `data: { turbo_frame: turbo_frame }` targets specific frame
3. **DaisyUI Input** - `class="input input-bordered"` for consistent styling
4. **Search Icon** - SVG positioned to the right of input
5. **Autocomplete Off** - Prevents browser autocomplete interference

## Stimulus Controller

### JavaScript Behavior
Located at: `app/javascript/controllers/admin/search_controller.js`

**Stimulus Values:**
- `url` (String) - Search endpoint URL
- `debounce` (Number) - Debounce delay in milliseconds (default: 300)

**Stimulus Targets:**
- `input` - The text input field
- `form` - The search form

**Actions:**
- `search()` - Triggered on input event, debounced form submission

**Behavior:**
```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "form"]
  static values = {
    url: String,
    debounce: { type: Number, default: 300 }
  }

  connect() {
    this.timeout = null
  }

  search() {
    clearTimeout(this.timeout)

    this.timeout = setTimeout(() => {
      this.formTarget.requestSubmit()
    }, this.debounceValue)
  }
}
```

## DaisyUI Styling

### Input Pattern
Uses DaisyUI's recommended input-with-icon pattern:

```erb
<label class="input input-bordered flex items-center gap-2">
  <input type="text" class="grow" placeholder="Search..." />
  <svg><!-- icon --></svg>
</label>
```

**Classes:**
- `input` - Base DaisyUI input component
- `input-bordered` - Adds border to input
- `flex items-center gap-2` - Flexbox layout with centered items and gap
- `grow` - Makes input take available space

**Visual Result:**
```
┌─────────────────────────────┐
│ Search...              🔍   │
└─────────────────────────────┘
```

## Usage Examples

### Artists Index Page
```erb
<!-- In app/views/admin/music/artists/index.html.erb -->

<%= render Admin::SearchComponent.new(
  url: admin_artists_path,
  turbo_frame: "artists_table",
  value: params[:q],
  placeholder: "Search artists..."
) %>

<%= turbo_frame_tag "artists_table" do %>
  <%= render "table", artists: @artists, pagy: @pagy %>
<% end %>
```

**Behavior:**
1. User types "beatles"
2. After 300ms debounce, form submits via Turbo
3. Request: `GET /admin/artists?q=beatles`
4. Response replaces `artists_table` frame with search results
5. Rest of page unchanged (no full reload)

### Albums Index Page
```erb
<!-- Reusing same component for albums -->

<%= render Admin::SearchComponent.new(
  url: admin_albums_path,
  turbo_frame: "albums_table",
  value: params[:q],
  placeholder: "Search albums..."
) %>

<%= turbo_frame_tag "albums_table" do %>
  <%= render "table", albums: @albums, pagy: @pagy %>
<% end %>
```

### Custom Search Endpoint
```erb
<!-- Using custom endpoint and parameter name -->

<%= render Admin::SearchComponent.new(
  url: search_admin_artists_path,
  turbo_frame: "search_results",
  param: "query",
  placeholder: "Find artists by name..."
) %>
```

## Turbo Frame Integration

### How It Works
1. **Component renders form** with `data: { turbo_frame: "artists_table" }`
2. **User types** triggering `input->admin--search#search`
3. **Debounce waits** 300ms for user to stop typing
4. **Form submits** via Turbo (AJAX request)
5. **Server responds** with HTML containing `<turbo-frame id="artists_table">`
6. **Turbo replaces** only the matching frame, preserving rest of page

### Benefits
- **No JavaScript needed** for pagination/sorting (handled by Turbo)
- **Fast perceived performance** - only table updates
- **Preserves scroll position** - search input stays visible
- **Browser history** - back button works
- **Accessible** - works without JavaScript (falls back to full page)

## Debouncing

### Why Debounce?
Without debouncing, typing "beatles" would trigger 7 requests:
```
b
be
bea
beat
beatl
beatle
beatles
```

With 300ms debounce, only fires after user stops typing:
```
beatles (one request)
```

### Configurable Delay
```erb
<%= render Admin::SearchComponent.new(
  url: admin_artists_path,
  turbo_frame: "artists_table",
  debounce: 500  # 500ms delay instead of 300ms
) %>
```

**Lower values** (100-200ms):
- More responsive
- More server requests
- Better for fast typists

**Higher values** (500-1000ms):
- Fewer server requests
- Feels less responsive
- Better for slow endpoints

## OpenSearch Integration

### Controller Endpoint
```ruby
# In Admin::Music::ArtistsController
def index
  if params[:q].present?
    # OpenSearch query
    search_results = ::Search::Music::Search::ArtistGeneral.call(params[:q], size: 1000)
    artist_ids = search_results.map { |r| r[:id].to_i }

    @artists = Music::Artist
      .includes(:categories)
      .in_order_of(:id, artist_ids)

    @pagy, @artists = pagy(@artists, items: 25)
  else
    # Regular query
    @artists = Music::Artist.all.order(:name)
    @pagy, @artists = pagy(@artists, items: 25)
  end
end
```

**Flow:**
1. Component submits `GET /admin/artists?q=beatles`
2. Controller checks `params[:q]`
3. If present, queries OpenSearch
4. Returns relevance-sorted results
5. Paginates with Pagy
6. Renders table partial into Turbo Frame

## Accessibility

### Keyboard Navigation
- Tab to focus input
- Type to search
- Escape to clear (browser default)
- Enter to submit immediately (bypasses debounce)

### Screen Readers
- Label wraps input for proper association
- Placeholder provides context
- Icon is decorative (no aria-label needed)
- Form submission announces results update (Turbo handles)

### No-JavaScript Fallback
If JavaScript disabled:
1. Form still renders
2. User can type and press Enter
3. Full page reload shows results
4. Degrades gracefully

## Performance Considerations

### Debouncing Benefits
- **Reduces server load** - 7 requests → 1 request
- **Faster response** - Server handles fewer concurrent requests
- **Better UX** - No partial results while typing

### Turbo Frame Benefits
- **Smaller payloads** - Only table HTML, not full page
- **Faster rendering** - Browser updates small DOM section
- **Preserved state** - Other page elements unchanged

### Caching Opportunities
```ruby
# In controller
def index
  if params[:q].present?
    cache_key = "admin_artist_search/#{params[:q]}/page/#{params[:page]}"
    @artists = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
      # ... search logic ...
    end
  end
end
```

## Related Components
- `Admin::TableComponent` - Works with search results
- `Admin::PaginationComponent` - Paginated search results
- Similar components for albums, songs, etc.

## Testing

### Component Test
```ruby
# test/components/admin/search_component_test.rb
require "test_helper"

class Admin::SearchComponentTest < ViewComponent::TestCase
  test "renders search form with correct attributes" do
    render_inline(Admin::SearchComponent.new(
      url: "/admin/artists",
      turbo_frame: "artists_table",
      placeholder: "Search artists..."
    ))

    assert_selector "form[action='/admin/artists']"
    assert_selector "input[placeholder='Search artists...']"
    assert_selector "[data-controller='admin--search']"
    assert_selector "[data-turbo-frame='artists_table']"
  end

  test "uses custom param name" do
    render_inline(Admin::SearchComponent.new(
      url: "/admin/artists",
      turbo_frame: "results",
      param: "query"
    ))

    assert_selector "input[name='query']"
  end
end
```

### Integration Test
```ruby
# test/controllers/admin/music/artists_controller_test.rb
test "should filter artists by search query" do
  sign_in_as(@admin_user, stub_auth: true)

  get admin_artists_path(q: "bowie")

  assert_response :success
  assert_select "turbo-frame#artists_table"
end
```

### Stimulus Controller Test
```javascript
// test/javascript/controllers/admin/search_controller.test.js
import { Application } from "@hotwired/stimulus"
import SearchController from "controllers/admin/search_controller"

describe("SearchController", () => {
  it("debounces search input", (done) => {
    const application = Application.start()
    application.register("admin--search", SearchController)

    // ... test debouncing behavior ...
  })
})
```

## Future Enhancements

### Potential Improvements
1. **Autocomplete Dropdown** - Show suggestions as user types
2. **Recent Searches** - Store and display recent searches
3. **Search Filters** - Add category/type filters
4. **Keyboard Shortcuts** - `/` to focus search (like GitHub)
5. **Clear Button** - X icon to clear input
6. **Loading Indicator** - Show spinner during search
7. **Empty State** - Custom message when no results
8. **Voice Search** - Browser speech recognition API

## Design Decisions

### Why ViewComponent?
- **Reusable** - Same component across all admin resources
- **Testable** - Unit test component in isolation
- **Encapsulated** - Logic and template together
- **Type Safe** - Ruby initialization parameters

### Why Stimulus?
- **Progressive Enhancement** - Works without JavaScript
- **Simple** - No complex state management
- **Hotwire Native** - Designed for Turbo integration
- **Lightweight** - No heavy framework overhead

### Why DaisyUI?
- **Consistent Styling** - Matches rest of admin UI
- **Accessible** - Built-in ARIA attributes
- **Responsive** - Mobile-friendly by default
- **Themeable** - Easy to customize appearance

## Related Documentation
- [DaisyUI Input Component](https://daisyui.com/components/input/)
- [Hotwire Turbo Frames](https://turbo.hotwired.dev/handbook/frames)
- [Stimulus Values API](https://stimulus.hotwired.dev/reference/values)
- [ViewComponent Guide](https://viewcomponent.org/)

## File Locations
- **Ruby Class**: `/home/shane/dev/the-greatest/web-app/app/components/admin/search_component.rb`
- **ERB Template**: `/home/shane/dev/the-greatest/web-app/app/components/admin/search_component/search_component.html.erb`
- **Stimulus JS**: `/home/shane/dev/the-greatest/web-app/app/javascript/controllers/admin/search_controller.js`
- **Component Test**: `/home/shane/dev/the-greatest/web-app/test/components/admin/search_component_test.rb`
