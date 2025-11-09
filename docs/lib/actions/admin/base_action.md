# Actions::Admin::BaseAction

## Summary
Base class for all custom admin actions across all domains. Provides a consistent interface for executing admin operations with standardized result handling.

## Purpose
- Defines the action execution pattern with `call` class method
- Provides `ActionResult` object for consistent return values
- Establishes helper methods for success/error/warning responses
- Used as parent class for domain-specific admin actions

## Inheritance
- Inherits from: None (base class)
- Inherited by: All admin action classes (`Actions::Admin::Music::*`, etc.)

## Architecture

### ActionResult Class
Encapsulates the result of an action execution.

**Attributes:**
- `status` - Symbol (`:success`, `:error`, or `:warning`)
- `message` - String message describing the result
- `data` - Optional hash of additional data

**Methods:**
- `success?` - Returns true if status is `:success`
- `error?` - Returns true if status is `:error`
- `warning?` - Returns true if status is `:warning`

**Example:**
```ruby
result = ActionResult.new(
  status: :success,
  message: "Artist ranking queued for calculation",
  data: { artist_id: 123 }
)

result.success?  # => true
result.message   # => "Artist ranking queued for calculation"
result.data      # => { artist_id: 123 }
```

## Public Class Methods

### `call(user:, models:, fields: {})`
Executes the action. This is the main entry point for all actions.

**Parameters:**
- `user:` (User) - The user executing the action (for authorization/audit)
- `models:` (Array) - Array of model instances to operate on (can be empty for index-level actions)
- `fields:` (Hash) - Optional hash of additional field values (default: `{}`)

**Returns:** `ActionResult` instance

**Example:**
```ruby
result = Actions::Admin::Music::RefreshArtistRanking.call(
  user: current_user,
  models: [@artist]
)

if result.success?
  flash[:notice] = result.message
else
  flash[:alert] = result.message
end
```

## Protected Helper Methods

### `succeed(message, data: nil)`
Creates a success ActionResult.

**Parameters:**
- `message` (String) - Success message
- `data:` (Hash, optional) - Additional data

**Returns:** `ActionResult` with status `:success`

**Example:**
```ruby
def call
  # ... do work ...
  succeed("Operation completed successfully", data: { count: 5 })
end
```

### `error(message, data: nil)`
Creates an error ActionResult.

**Parameters:**
- `message` (String) - Error message
- `data:` (Hash, optional) - Additional data

**Returns:** `ActionResult` with status `:error`

**Example:**
```ruby
def call
  return error("Configuration not found") unless config.present?
  # ... continue ...
end
```

### `warning(message, data: nil)`
Creates a warning ActionResult.

**Parameters:**
- `message` (String) - Warning message
- `data:` (Hash, optional) - Additional data

**Returns:** `ActionResult` with status `:warning`

**Example:**
```ruby
def call
  return warning("No items found to process") if models.empty?
  # ... continue ...
end
```

## Usage Pattern

### Implementing a New Action

```ruby
module Actions
  module Admin
    module Music
      class MyCustomAction < Actions::Admin::BaseAction
        def call
          # Validate preconditions
          return error("No artists selected") if models.empty?

          # Perform the action
          models.each do |artist|
            # ... do work ...
          end

          # Return success
          succeed("#{models.count} artists processed")
        end
      end
    end
  end
end
```

### Calling from Controllers

```ruby
# Single model action (member route)
def execute_action
  action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
  result = action_class.call(user: current_user, models: [@artist])

  flash[:notice] = result.message if result.success?
  flash[:alert] = result.message if result.error?

  redirect_to admin_artist_path(@artist)
end

# Bulk action (collection route)
def bulk_action
  artists = Music::Artist.where(id: params[:artist_ids])
  action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
  result = action_class.call(user: current_user, models: artists)

  # ... handle result ...
end

# Index action (no models)
def index_action
  action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
  result = action_class.call(user: current_user, models: [])

  # ... handle result ...
end
```

## Design Decisions

### Why Not ActiveInteraction?
- **Simplicity**: BaseAction is lightweight without external dependencies
- **Avo Compatibility**: Similar pattern to Avo Pro actions for easy migration
- **Flexibility**: Easy to extend with domain-specific behavior
- **No Framework Lock-in**: Custom pattern means full control

### Why Three Result Types?
- **Success**: Operation completed as expected
- **Error**: Operation failed, user should be alerted
- **Warning**: Operation completed but with caveats (e.g., "No items to process")

### Why Accept Empty Models Array?
Index-level actions operate globally without specific models:
```ruby
# Example: Refresh all rankings (no specific artists)
Actions::Admin::Music::RefreshAllArtistsRankings.call(
  user: current_user,
  models: []  # Empty array for global operations
)
```

## Action Types

### Single Model Actions (Member Routes)
Operate on one specific model instance.

**Example:** `RefreshArtistRanking`
- Route: `POST /admin/artists/:id/execute_action`
- Models: `[@artist]`

### Bulk Actions (Collection Routes)
Operate on multiple selected model instances.

**Example:** `GenerateArtistDescription`
- Route: `POST /admin/artists/bulk_action`
- Models: `[artist1, artist2, artist3]`

### Index Actions (Collection Routes)
Operate globally without specific models.

**Example:** `RefreshAllArtistsRankings`
- Route: `POST /admin/artists/index_action`
- Models: `[]`

## Turbo Stream Integration

Actions work seamlessly with Turbo Streams for real-time UI updates:

```ruby
respond_to do |format|
  format.turbo_stream do
    render turbo_stream: turbo_stream.replace(
      "flash",
      partial: "admin/shared/flash",
      locals: { result: result }
    )
  end
  format.html { redirect_to admin_artists_path, notice: result.message }
end
```

## Background Job Pattern

Many actions queue background jobs instead of executing synchronously:

```ruby
def call
  artist_ids = models.map(&:id)

  artist_ids.each do |artist_id|
    ::Music::ArtistDescriptionJob.perform_async(artist_id)
  end

  succeed("#{artist_ids.length} artist(s) queued for processing")
end
```

This pattern:
- Returns immediately to the user
- Processes heavy work in background
- Provides responsive admin experience

## Related Classes
- `Actions::Admin::Music::GenerateArtistDescription` - Example bulk action
- `Actions::Admin::Music::RefreshArtistRanking` - Example single model action
- `Actions::Admin::Music::RefreshAllArtistsRankings` - Example index action
- `Admin::Music::ArtistsController` - Controller that executes actions

## Testing
Test actions by verifying job queueing and result handling:

```ruby
test "should queue job and return success" do
  ::Music::ArtistDescriptionJob.expects(:perform_async).with(@artist.id).once

  result = GenerateArtistDescription.call(
    user: @admin_user,
    models: [@artist]
  )

  assert result.success?
  assert_equal "1 artist(s) queued for AI description generation.", result.message
end
```

See: `/test/lib/actions/admin/music/*_test.rb`

## File Location
`/home/shane/dev/the-greatest/web-app/app/lib/actions/admin/base_action.rb`
