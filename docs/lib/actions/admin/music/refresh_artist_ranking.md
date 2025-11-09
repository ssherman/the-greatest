# Actions::Admin::Music::RefreshArtistRanking

## Summary
Single-model admin action that queues a ranking calculation job for one specific artist. Allows admins to manually trigger ranking recalculation from the artist show page.

## Purpose
- Trigger ranking recalculation for a single artist
- Used after manual data corrections or when rankings seem stale
- Queues background job to calculate weighted rank
- Provides immediate feedback while processing happens asynchronously

## Inheritance
Inherits from: `Actions::Admin::BaseAction`

## Action Type
**Single Model Action** - Operates on one specific model instance (member route)

## Route
```ruby
POST /admin/artists/:id/execute_action
params: { action_name: "RefreshArtistRanking" }
```

## Public Methods

### `call`
Queues a ranking calculation job for the artist.

**Behavior:**
1. Finds the default primary global ranking configuration
2. Validates that a configuration exists
3. Queues `Music::CalculateArtistRankingJob` with artist and config
4. Returns success with descriptive message

**Returns:**
- `ActionResult` with success status if configuration found
- `ActionResult` with error status if no configuration exists

**Example:**
```ruby
result = Actions::Admin::Music::RefreshArtistRanking.call(
  user: current_user,
  models: [@artist]
)

# => ActionResult(
#      status: :success,
#      message: "Artist ranking calculation queued"
#    )
```

## Ranking Configuration

### Finding the Configuration
Uses the primary global ranking configuration for artists:

```ruby
primary_config = ::Music::Artists::RankingConfiguration.default_primary
```

**Why `::` prefix?**
Inside the `Actions::Admin::Music` namespace, Ruby would look for `Actions::Admin::Music::Music::Artists` without the `::` prefix. The `::` forces resolution from the top-level namespace.

**What is `default_primary`?**
```ruby
# In Music::Artists::RankingConfiguration
def self.default_primary
  global.primary.first
end
```

Returns the first primary global ranking configuration, which defines:
- Weighting formula
- Penalty calculations
- Ranking algorithm parameters

### Error Handling
```ruby
if primary_config.nil?
  return error("No primary global ranking configuration found for artists.")
end
```

If no configuration exists, the action returns an error instead of queuing a job that would fail.

## Background Job Integration

### Job Queued
`Music::CalculateArtistRankingJob` - Sidekiq job that calculates weighted ranking

**Job Parameters:**
- `artist_id` - ID of artist to calculate ranking for
- `ranking_configuration_id` - ID of ranking configuration to use

**Job Behavior:**
- Fetches all ranked lists containing the artist
- Applies weighting formula from configuration
- Calculates penalties (voter count, estimated, etc.)
- Updates artist's `calculated_weight` field
- Updates artist's ranking position

**Example:**
```ruby
::Music::CalculateArtistRankingJob.perform_async(
  models.first.id,
  primary_config.id
)
```

## Usage in Admin Interface

### From Artist Show Page

**Action Button:**
```erb
<%= button_to "Refresh Ranking",
    execute_action_admin_artist_path(@artist, action_name: "RefreshArtistRanking"),
    method: :post,
    class: "btn btn-sm btn-outline" %>
```

**Controller Execution:**
```ruby
# In Admin::Music::ArtistsController
def execute_action
  action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
  result = action_class.call(user: current_user, models: [@artist])

  respond_to do |format|
    format.turbo_stream do
      render turbo_stream: turbo_stream.replace(
        "flash",
        partial: "admin/shared/flash",
        locals: { result: result }
      )
    end
    format.html do
      flash[:notice] = result.message if result.success?
      flash[:alert] = result.message if result.error?
      redirect_to admin_artist_path(@artist)
    end
  end
end
```

## When to Use This Action

### Common Scenarios
1. **After Manual Edits** - Updated artist's albums, categories, or other ranking factors
2. **Data Corrections** - Fixed incorrect list placements
3. **Testing** - Verifying ranking algorithm changes
4. **User Reports** - User noticed ranking seems incorrect
5. **Audit** - Checking specific artist's ranking calculation

### When NOT to Use
- **Mass Updates** - Use `RefreshAllArtistsRankings` instead
- **Scheduled Maintenance** - Set up automated job instead
- **Continuous Updates** - Consider real-time recalculation on model changes

## Why Asynchronous?

### Benefits
1. **Immediate Response** - User doesn't wait for calculation
2. **Complex Calculation** - Weighted ranking involves multiple queries
3. **Consistency** - Same job used for scheduled and manual recalculations
4. **Error Isolation** - Job failures don't break admin interface

### Trade-offs
- Ranking not immediately updated (need to refresh page)
- Requires Sidekiq infrastructure
- Need to monitor for failed jobs

## Error Handling

### Missing Configuration
```ruby
primary_config = ::Music::Artists::RankingConfiguration.default_primary

if primary_config.nil?
  return error("No primary global ranking configuration found for artists.")
end
```

This prevents queueing a job that would fail due to missing configuration.

### Job-Level Errors
The job itself handles:
- Artist not found
- Invalid configuration
- Database errors
- Calculation errors

Failed jobs appear in Sidekiq dead queue for manual inspection.

## Dependencies
- **Sidekiq**: Background job processing
- **Music::CalculateArtistRankingJob**: Job performing the calculation
- **Music::Artists::RankingConfiguration**: Defines ranking algorithm
- **Music::Artist**: Model being updated

## Related Classes
- `Actions::Admin::BaseAction` - Parent class
- `Music::CalculateArtistRankingJob` - Background job
- `Music::Artists::RankingConfiguration` - Configuration model
- `Admin::Music::ArtistsController` - Executes the action

## Related Actions
- `RefreshAllArtistsRankings` - Recalculates all artists (index-level)
- `GenerateArtistDescription` - AI description generation (bulk)
- Similar ranking actions for albums, songs, etc.

## Testing

### Test File
`/test/lib/actions/admin/music/refresh_artist_ranking_test.rb`

### Example Tests
```ruby
test "should queue job for single artist" do
  config = music_artists_ranking_configurations(:default_primary)

  ::Music::CalculateArtistRankingJob.expects(:perform_async)
    .with(@artist1.id, config.id)
    .once

  result = RefreshArtistRanking.call(
    user: @admin_user,
    models: [@artist1]
  )

  assert result.success?
  assert_equal "Artist ranking calculation queued", result.message
end

test "should return error when no primary config exists" do
  Music::Artists::RankingConfiguration.stubs(:default_primary).returns(nil)

  result = RefreshArtistRanking.call(
    user: @admin_user,
    models: [@artist1]
  )

  assert result.error?
  assert_includes result.message, "No primary global ranking configuration"
end
```

### Key Test Scenarios
1. ✅ Queues job with correct parameters
2. ✅ Returns error when configuration missing
3. ✅ Uses default_primary configuration
4. ✅ Returns appropriate success message

## Performance Considerations

### Queueing Performance
- Very fast - just inserting job into Redis
- O(1) operation
- Typical: < 10ms

### Job Processing
- Moderate speed - depends on number of lists
- Typical: 100ms - 2 seconds per artist
- Database-intensive (joins, aggregations)

## Future Enhancements

### Potential Improvements
1. **Real-time Updates** - WebSocket to show updated ranking
2. **Calculation Preview** - Show what the new ranking would be before saving
3. **Change Log** - Track ranking changes over time
4. **Batch Mode** - Combine with other pending calculations
5. **Configuration Override** - Allow selecting alternate ranking configuration

## File Location
`/home/shane/dev/the-greatest/web-app/app/lib/actions/admin/music/refresh_artist_ranking.rb`
