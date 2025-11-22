# [088] - Song Wizard: Step 0 - Import Source Choice

## Status
- **Status**: Planned
- **Priority**: High
- **Created**: 2025-01-19
- **Part**: 3 of 10

## Overview
Implement Step 0 where users choose between MusicBrainz series import (fast path) or custom HTML import (full wizard). MusicBrainz path skips to import step directly.

## Acceptance Criteria
- [ ] Step 0 view shows two radio options: MusicBrainz Series, Custom HTML
- [ ] Choosing MusicBrainz Series jumps to step 5 (import)
- [ ] Choosing Custom HTML advances to step 1 (parse)
- [ ] `wizard_state["import_source"]` stores choice
- [ ] Progress indicator adapts: 3 steps for MusicBrainz, 7 for custom

## Key Components

### View
**File**: `app/views/admin/music/songs/list_wizard/steps/_source.html.erb`
- Two radio card options
- Submit button "Continue →"

### Controller Logic
**File**: `app/controllers/admin/music/songs/list_wizard_controller.rb`
Already stubbed in [087], update:
```ruby
when "source"
  if params[:import_source] == "musicbrainz_series"
    @list.update!(wizard_state: @list.wizard_state.merge(
      "current_step" => 5,
      "import_source" => "musicbrainz_series"
    ))
    redirect_to step 5 (import)
  else
    @list.update!(wizard_state: @list.wizard_state.merge(
      "import_source" => "custom_html"
    ))
    advance to step 1
  end
```

### MusicBrainz Series Import
**Service**: Reuse existing `DataImporters::Music::Lists::ImportFromMusicbrainzSeries`
**Reference**: `docs/admin/actions/import_from_musicbrainz_series.md`
**Job**: Create `Music::Songs::ImportFromMusicbrainzSeriesJob` (similar to albums)

## Tests
- [ ] Selecting MusicBrainz advances to step 5
- [ ] Selecting Custom HTML advances to step 1
- [ ] wizard_state stores import_source correctly

## Related
- **Previous**: [087] UI Shell
- **Next**: [089] Step 1: Parse
