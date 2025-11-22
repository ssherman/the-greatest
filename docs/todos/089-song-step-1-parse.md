# [089] - Song Wizard: Step 1 - Parse HTML

## Status
- **Status**: Planned
- **Priority**: High
- **Created**: 2025-01-19
- **Part**: 4 of 10

## Overview
Parse raw HTML into unverified list_items with metadata. Reuses existing AI parser but creates list_items instead of populating items_json.

## Acceptance Criteria
- [ ] "Start Parsing" button enqueues job
- [ ] Progress bar shows parsing progress
- [ ] Job creates `list_items` with `verified: false`
- [ ] Each item has metadata: `{rank, title, artists[], album, release_year}`
- [ ] Polling shows progress and enables "Next" when complete

## Key Components

### View
**File**: `app/views/admin/music/songs/list_wizard/steps/_parse.html.erb`
- Shows list.raw_html preview
- Progress bar (data-wizard-step-target="progressBar")
- Status text (data-wizard-step-target="statusText")
- Next button disabled until job complete

### Job
**File**: `app/sidekiq/music/songs/wizard_parse_list_job.rb`
```ruby
def perform(list_id)
  list = Music::Songs::List.find(list_id)
  list.update_wizard_job_status(status: 'running', progress: 0)

  # Reuse existing AI parser
  result = Services::Ai::Tasks::Lists::Music::SongsRawParserTask.new(parent: list).call

  # Create list_items instead of items_json
  result.data[:parsed][:songs].each do |song_data|
    list.list_items.create!(
      listable_type: "Music::Song",
      metadata: song_data,
      verified: false,
      position: song_data[:rank] || 0
    )
  end

  list.update_wizard_job_status(status: 'completed', progress: 100)
end
```

### AI Parser (Existing)
**Service**: `Services::Ai::Tasks::Lists::Music::SongsRawParserTask`
**Location**: `app/lib/services/ai/tasks/lists/music/songs_raw_parser_task.rb`
No changes needed - already returns parsed song data

## Tests
- [ ] Job creates unverified list_items
- [ ] Metadata contains all parsed fields
- [ ] Progress updates during parsing
- [ ] Next button enables on completion

## Related
- **Previous**: [088] Step 0: Source
- **Next**: [090] Step 2: Enrich
- **Reference**: Existing parser in `app/lib/services/ai/tasks/lists/music/songs_raw_parser_task.rb`
