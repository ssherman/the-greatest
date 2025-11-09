# Actions::Admin::Music::GenerateArtistDescription

## Summary
Bulk admin action that queues AI description generation jobs for selected artists. Allows admins to trigger OpenAI-powered description generation for multiple artists at once.

## Purpose
- Queue background jobs to generate AI descriptions for artists
- Support bulk operations on multiple artists
- Provide immediate feedback while processing happens asynchronously
- Used from admin artists index page with bulk selection

## Inheritance
Inherits from: `Actions::Admin::BaseAction`

## Action Type
**Bulk Action** - Operates on multiple selected model instances

## Route
```ruby
POST /admin/artists/bulk_action
params: { action_name: "GenerateArtistDescription", artist_ids: [1, 2, 3] }
```

## Public Methods

### `call`
Queues AI description generation jobs for all selected artists.

**Behavior:**
1. Extracts artist IDs from models array
2. Queues one `Music::ArtistDescriptionJob` per artist
3. Returns success with count of queued jobs

**Returns:** `ActionResult` with success status and message

**Example:**
```ruby
result = Actions::Admin::Music::GenerateArtistDescription.call(
  user: current_user,
  models: [artist1, artist2, artist3]
)

# => ActionResult(
#      status: :success,
#      message: "3 artist(s) queued for AI description generation."
#    )
```

## Background Job Integration

### Job Queued
`Music::ArtistDescriptionJob` - Sidekiq job that calls OpenAI API

**Job Parameters:**
- `artist_id` - ID of artist to generate description for

**Job Behavior:**
- Fetches artist details and discography
- Calls OpenAI API with structured prompt
- Updates artist's `description` field
- Handles API errors gracefully

**Example:**
```ruby
# Action queues this job for each artist
::Music::ArtistDescriptionJob.perform_async(artist_id)
```

## Usage in Admin Interface

### From Artists Index Page

**Step 1: User Selection**
```erb
<!-- Artists table with checkboxes -->
<input type="checkbox" name="artist_ids[]" value="<%= artist.id %>" />
```

**Step 2: Bulk Action Dropdown**
```erb
<%= form_with url: bulk_action_admin_artists_path, method: :post do %>
  <%= select_tag :action_name, options_for_select([
    ["Generate AI Description", "GenerateArtistDescription"],
    # ... other actions
  ]) %>
  <%= submit_tag "Execute", class: "btn btn-primary" %>
<% end %>
```

**Step 3: Controller Execution**
```ruby
# In Admin::Music::ArtistsController
def bulk_action
  artists = Music::Artist.where(id: params[:artist_ids])
  action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
  result = action_class.call(user: current_user, models: artists)

  flash[:notice] = result.message
  redirect_to admin_artists_path
end
```

## Why Asynchronous?

### Benefits
1. **Immediate Response** - User doesn't wait for OpenAI API calls
2. **Scalability** - Can queue hundreds of artists without timeout
3. **Error Isolation** - Failed jobs don't affect other artists
4. **Rate Limiting** - Sidekiq can throttle API calls to avoid rate limits

### Trade-offs
- Results not immediately visible (need to refresh page)
- Requires background job infrastructure (Sidekiq)
- Need monitoring for failed jobs

## Error Handling

### Action Level
The action itself doesn't fail - it just queues jobs:
```ruby
# Always succeeds if models are provided
artist_ids.each do |artist_id|
  ::Music::ArtistDescriptionJob.perform_async(artist_id)
end
succeed("#{artist_ids.length} artist(s) queued for AI description generation.")
```

### Job Level
Errors handled by `Music::ArtistDescriptionJob`:
- API timeout/failure
- Invalid artist data
- OpenAI rate limits
- Network errors

Failed jobs appear in Sidekiq's dead queue for manual retry.

## Dependencies
- **Sidekiq**: Background job processing
- **Music::ArtistDescriptionJob**: Job that performs AI generation
- **OpenAI API**: Via job, generates descriptions
- **Music::Artist**: Model being updated

## Related Classes
- `Actions::Admin::BaseAction` - Parent class with result handling
- `Music::ArtistDescriptionJob` - Background job for API calls
- `Admin::Music::ArtistsController` - Controller executing the action
- `Music::Artist` - Model being updated

## Related Actions
- `GenerateAlbumDescription` - Similar action for albums
- `RefreshArtistRanking` - Single artist ranking update
- `RefreshAllArtistsRankings` - Global ranking recalculation

## Testing

### Test File
`/test/lib/actions/admin/music/generate_artist_description_test.rb`

### Example Test
```ruby
test "should queue job for multiple artists" do
  ::Music::ArtistDescriptionJob.expects(:perform_async).with(@artist1.id).once
  ::Music::ArtistDescriptionJob.expects(:perform_async).with(@artist2.id).once

  result = GenerateArtistDescription.call(
    user: @admin_user,
    models: [@artist1, @artist2]
  )

  assert result.success?
  assert_equal "2 artist(s) queued for AI description generation.", result.message
end
```

### Key Test Scenarios
1. ✅ Single artist queues one job
2. ✅ Multiple artists queue multiple jobs
3. ✅ Empty models array queues zero jobs
4. ✅ Returns success message with correct count

## Performance Considerations

### Queueing Performance
- Very fast - just inserting jobs into Redis
- O(n) where n = number of artists
- Typical: < 100ms for 100 artists

### Job Processing
- Slow - OpenAI API calls take 2-10 seconds each
- Sidekiq concurrency setting determines parallelism
- Rate limits may require throttling

## Future Enhancements

### Potential Improvements
1. **Batch API Calls** - Send multiple artists to OpenAI in one request
2. **Selective Generation** - Skip artists with existing descriptions
3. **Quality Validation** - Check generated descriptions before saving
4. **Progress Tracking** - WebSocket updates showing completion status
5. **Description History** - Keep previous versions for comparison

## File Location
`/home/shane/dev/the-greatest/web-app/app/lib/actions/admin/music/generate_artist_description.rb`
