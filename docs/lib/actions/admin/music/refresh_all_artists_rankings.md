# Actions::Admin::Music::RefreshAllArtistsRankings

## Summary
Index-level admin action that queues a job to recalculate rankings for ALL artists in the system. Used for scheduled maintenance or after global ranking configuration changes.

## Purpose
- Trigger ranking recalculation for every artist in the database
- Used after changing ranking configuration or weighting formulas
- Queues single background job that processes all artists
- Provides immediate feedback while processing happens asynchronously

## Inheritance
Inherits from: `Actions::Admin::BaseAction`

## Action Type
**Index Action** - Operates globally without specific models (operates on all records)

## Route
```ruby
POST /admin/artists/index_action
params: { action_name: "RefreshAllArtistsRankings" }
```

## Public Methods

### `call`
Queues a job to recalculate rankings for all artists.

**Behavior:**
1. Finds the default primary global ranking configuration
2. Validates that a configuration exists
3. Queues `Music::CalculateAllArtistsRankingsJob` with configuration ID
4. Returns success with descriptive message

**Parameters:**
- `models` - Empty array (not used for index-level actions)

**Returns:**
- `ActionResult` with success status if configuration found
- `ActionResult` with error status if no configuration exists

**Example:**
```ruby
result = Actions::Admin::Music::RefreshAllArtistsRankings.call(
  user: current_user,
  models: []  # Empty array for index actions
)

# => ActionResult(
#      status: :success,
#      message: "All artist rankings queued for recalculation."
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

Returns the first primary global ranking configuration.

### Error Handling
```ruby
if primary_config.nil?
  return error("No primary global ranking configuration found for artists.")
end
```

## Background Job Integration

### Job Queued
`Music::CalculateAllArtistsRankingsJob` - Sidekiq job that processes ALL artists

**Job Parameters:**
- `ranking_configuration_id` - ID of ranking configuration to use

**Job Behavior:**
- Fetches ALL artists from database
- For each artist:
  - Fetches all ranked lists containing the artist
  - Applies weighting formula from configuration
  - Calculates penalties
  - Updates artist's `calculated_weight` field
  - Updates artist's ranking position
- Processes in batches to avoid memory issues
- Logs progress for monitoring

**Example:**
```ruby
::Music::CalculateAllArtistsRankingsJob.perform_async(primary_config.id)
```

## Usage in Admin Interface

### From Artists Index Page

**Index Action Button:**
```erb
<%= button_to "Recalculate All Rankings",
    index_action_admin_artists_path(action_name: "RefreshAllArtistsRankings"),
    method: :post,
    class: "btn btn-warning",
    data: { confirm: "This will recalculate rankings for ALL artists. Continue?" } %>
```

**Controller Execution:**
```ruby
# In Admin::Music::ArtistsController
def index_action
  action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
  result = action_class.call(user: current_user, models: [])

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
      redirect_to admin_artists_path
    end
  end
end
```

## When to Use This Action

### Common Scenarios
1. **Configuration Changes** - After modifying ranking formula or weights
2. **Penalty Updates** - After changing penalty calculation rules
3. **Data Migration** - After bulk importing new lists or artists
4. **Scheduled Maintenance** - Weekly/monthly recalculation via cron
5. **Algorithm Updates** - After deploying new ranking algorithm
6. **Audit/Verification** - Ensuring all rankings are current

### When NOT to Use
- **Single Artist Updates** - Use `RefreshArtistRanking` instead
- **Small Batch** - Use bulk action on specific artists
- **Real-time Updates** - Consider automated triggers on model changes
- **Frequent Updates** - Too expensive to run constantly

## Performance Considerations

### Queueing Performance
- Very fast - just inserting one job into Redis
- O(1) operation
- Typical: < 10ms

### Job Processing Performance
- **Very Slow** - processes EVERY artist in database
- Depends on:
  - Total number of artists (could be 100,000+)
  - Number of lists each artist appears on
  - Complexity of ranking formula
  - Database performance
- Typical: 5-30 minutes for large datasets
- Memory: Processes in batches to avoid OOM

**Example Processing Time:**
```
1,000 artists × 2 seconds each = 33 minutes
10,000 artists × 2 seconds each = 5.5 hours
```

### Optimization Strategies
1. **Batch Processing** - Job processes artists in chunks
2. **Connection Pooling** - Reuses database connections
3. **Selective Updates** - Skip artists with no changes
4. **Parallel Processing** - Multiple Sidekiq workers
5. **Off-Peak Scheduling** - Run during low-traffic hours

## Why Asynchronous?

### Critical Reasons
1. **Duration** - Would timeout HTTP request (30+ minutes)
2. **Resource Usage** - Heavy database load
3. **User Experience** - Admin shouldn't wait
4. **Error Recovery** - Job retry on failure
5. **Progress Tracking** - Can monitor Sidekiq progress

### Trade-offs
- Rankings not immediately updated
- Requires robust Sidekiq setup
- Need monitoring for failures
- May impact database performance during execution

## Error Handling

### Action Level
```ruby
primary_config = ::Music::Artists::RankingConfiguration.default_primary

if primary_config.nil?
  return error("No primary global ranking configuration found for artists.")
end
```

Prevents queueing a job that would immediately fail.

### Job Level
The job handles:
- Invalid configuration
- Database connection errors
- Individual artist calculation failures
- Memory issues
- Timeout errors

Job logs errors and continues with remaining artists.

## Monitoring

### Key Metrics to Track
1. **Job Duration** - How long does full recalculation take?
2. **Success Rate** - Are all artists processed?
3. **Error Rate** - Which artists fail calculation?
4. **Database Load** - CPU/memory impact
5. **Queue Depth** - Is job queued or running?

### Sidekiq Monitoring
```ruby
# Check if job is running
Sidekiq::Workers.new.each do |process_id, thread_id, work|
  puts work['payload']['class'] # => "Music::CalculateAllArtistsRankingsJob"
end

# Check queue depth
Sidekiq::Queue.new.size
```

## Dependencies
- **Sidekiq**: Background job processing
- **Music::CalculateAllArtistsRankingsJob**: Job doing the calculation
- **Music::Artists::RankingConfiguration**: Defines ranking algorithm
- **Music::Artist**: Model being updated (all records)
- **Database**: Heavy read/write operations

## Related Classes
- `Actions::Admin::BaseAction` - Parent class
- `Music::CalculateAllArtistsRankingsJob` - Background job
- `Music::Artists::RankingConfiguration` - Configuration model
- `Admin::Music::ArtistsController` - Executes the action

## Related Actions
- `RefreshArtistRanking` - Single artist recalculation
- `GenerateArtistDescription` - Bulk AI description generation
- Similar index actions for albums, songs, etc.

## Testing

### Test File
`/test/lib/actions/admin/music/refresh_all_artists_rankings_test.rb`

### Example Tests
```ruby
test "should queue job for all artists" do
  config = music_artists_ranking_configurations(:default_primary)

  ::Music::CalculateAllArtistsRankingsJob.expects(:perform_async)
    .with(config.id)
    .once

  result = RefreshAllArtistsRankings.call(
    user: @admin_user,
    models: []  # Empty for index actions
  )

  assert result.success?
  assert_equal "All artist rankings queued for recalculation.", result.message
end

test "should return error when no primary config exists" do
  Music::Artists::RankingConfiguration.stubs(:default_primary).returns(nil)

  result = RefreshAllArtistsRankings.call(
    user: @admin_user,
    models: []
  )

  assert result.error?
  assert_includes result.message, "No primary global ranking configuration"
end
```

### Key Test Scenarios
1. ✅ Queues job with configuration ID
2. ✅ Returns error when configuration missing
3. ✅ Accepts empty models array
4. ✅ Returns appropriate success message

## Scheduling

### Automated Execution
Set up cron job or Sidekiq scheduled job:

```ruby
# config/schedule.rb (using whenever gem)
every :sunday, at: '2am' do
  runner "Actions::Admin::Music::RefreshAllArtistsRankings.call(user: User.admin.first, models: [])"
end
```

Or use Sidekiq-cron:
```ruby
# config/initializers/sidekiq.rb
Sidekiq::Cron::Job.create(
  name: 'Recalculate All Artist Rankings',
  cron: '0 2 * * 0', # Sunday at 2am
  class: 'Music::CalculateAllArtistsRankingsJob',
  args: [Music::Artists::RankingConfiguration.default_primary.id]
)
```

## Future Enhancements

### Potential Improvements
1. **Progress Bar** - Real-time progress via WebSocket
2. **Incremental Updates** - Only recalculate changed artists
3. **Priority Queue** - Process popular artists first
4. **Diff Report** - Show ranking changes summary
5. **Dry Run Mode** - Calculate without saving
6. **Parallel Jobs** - Split into multiple concurrent jobs
7. **Smart Scheduling** - Detect off-peak times automatically

## Warning Messages

Consider adding confirmation dialog due to resource intensity:

```erb
<%= button_to "Recalculate All Rankings",
    index_action_admin_artists_path(action_name: "RefreshAllArtistsRankings"),
    method: :post,
    class: "btn btn-warning",
    data: {
      confirm: "This will recalculate rankings for ALL artists. " \
               "This is a heavy operation that may take 30+ minutes. " \
               "Continue?"
    } %>
```

## File Location
`/home/shane/dev/the-greatest/web-app/app/lib/actions/admin/music/refresh_all_artists_rankings.rb`
