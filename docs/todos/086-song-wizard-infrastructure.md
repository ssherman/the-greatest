# [086] - Song List Wizard Infrastructure

## Status
- **Status**: Planned
- **Priority**: High
- **Created**: 2025-01-19
- **Started**: Not started
- **Completed**: Not completed
- **Developer**: AI + Human

## Overview
Set up the foundational infrastructure for the Song List Wizard: database migration, model helpers, and route configuration. This provides the backbone for wizard state tracking using polling-based job status updates.

## Context

This is **Part 1 of 10** in the Song List Wizard implementation:

1. **[086] Infrastructure** ← You are here
2. [087] UI Shell & Navigation
3. [088] Step 0: Import Source Choice
4. [089] Step 1: Parse HTML
5. [090] Step 2: Enrich
6. [091] Step 3: Validation
7. [092] Step 4: Review UI
8. [093] Step 4: Actions
9. [094] Step 5: Import
10. [095] Polish & Integration

### The Problem

Currently, lists require manual intervention with items_json:
- Copy JSON from database
- Edit in external text editor
- Paste back via Rails console
- Technical users only

### The Solution

Multi-step wizard with:
- Browser-based UI for all steps
- Background jobs with progress tracking
- Polling-based status updates (no WebSockets needed)
- State stored in `list.wizard_state` JSONB field

### Why JSONB Field Instead of Separate Table?

✅ **Simpler schema** - Just one column, no joins
✅ **No querying** - Only for display, not filtering
✅ **Single user** - No concurrency issues
✅ **Atomic updates** - Single row update
✅ **Follows pattern** - Matches existing `items_json` usage

## Requirements

### Functional Requirements

#### FR-1: Database Schema
- [ ] Add `wizard_state` JSONB column to `lists` table
- [ ] Default value: `{}`
- [ ] Stores: current step, job status, job progress, job metadata, step data

#### FR-2: List Model Helpers
- [ ] `wizard_current_step` - Returns current step index (0-5)
- [ ] `wizard_job_status` - Returns 'idle', 'running', 'completed', 'failed'
- [ ] `wizard_job_progress` - Returns 0-100
- [ ] `wizard_job_error` - Returns error message or nil
- [ ] `wizard_job_metadata` - Returns hash with job details
- [ ] `wizard_in_progress?` - Returns true if wizard started but not completed
- [ ] `update_wizard_job_status(status:, progress:, error:, metadata:)` - Updates job status
- [ ] `reset_wizard!` - Resets wizard state to initial values

#### FR-3: ListItem Indexes
- [ ] Add index on `(list_id, verified)` for efficient filtering
- [ ] Add index on `(verified, listable_id)` for orphan cleanup

#### FR-4: Routes Configuration
- [ ] Wizard routes under `/admin/music/songs/lists/:list_id/wizard`
- [ ] Step routes: `step/:step` (show step)
- [ ] Status endpoint: `step/:step/status` (polling endpoint)
- [ ] Navigation routes: `step/:step/advance`, `step/:step/back`
- [ ] Restart route: `restart`

### Non-Functional Requirements

#### NFR-1: Performance
- [ ] JSONB field operations complete in < 10ms
- [ ] Wizard helper methods cached per request

#### NFR-2: Data Integrity
- [ ] JSONB field always valid JSON
- [ ] Safe defaults for all helper methods (never raise on missing keys)

## Acceptance Criteria

### Migration
- [ ] Migration creates `wizard_state` column with JSONB type
- [ ] Default value is `{}` (empty hash)
- [ ] Migration is reversible
- [ ] Can run migration without errors on existing data

### Model Helpers
- [ ] All helper methods return safe defaults when wizard_state is empty
- [ ] `update_wizard_job_status` merges new data with existing state
- [ ] `reset_wizard!` sets all required keys with proper initial values
- [ ] Helper methods tested with 100% coverage

### Indexes
- [ ] Indexes created without errors
- [ ] Query planner uses indexes for `list_items.unverified.where(list_id: X)` queries

### Routes
- [ ] All wizard routes accessible
- [ ] Routes follow RESTful naming conventions
- [ ] Routes namespaced correctly under admin/music/songs

## Technical Approach

### Database Migration

**File**: `db/migrate/YYYYMMDDHHMMSS_add_wizard_state_to_lists.rb`

```ruby
class AddWizardStateToLists < ActiveRecord::Migration[8.0]
  def change
    add_column :lists, :wizard_state, :jsonb, default: {}
  end
end
```

**Rollback**:
```ruby
def down
  remove_column :lists, :wizard_state
end
```

### ListItem Indexes Migration

**File**: `db/migrate/YYYYMMDDHHMMSS_add_wizard_indexes_to_list_items.rb`

```ruby
class AddWizardIndexesToListItems < ActiveRecord::Migration[8.0]
  def change
    add_index :list_items, [:list_id, :verified], name: 'index_list_items_on_list_id_and_verified'
    add_index :list_items, [:verified, :listable_id], name: 'index_list_items_on_verified_and_listable_id'
  end
end
```

### List Model Helper Methods

**File**: `app/models/list.rb`

Add these methods to the List model:

```ruby
class List < ApplicationRecord
  # Existing code...

  # === Wizard State Helpers ===

  # Returns the current wizard step (0-6)
  # Steps: 0=source, 1=parse, 2=enrich, 3=validate, 4=review, 5=import, 6=complete
  def wizard_current_step
    wizard_state.fetch("current_step", 0)
  end

  # Returns job status: 'idle', 'running', 'completed', 'failed'
  def wizard_job_status
    wizard_state.fetch("job_status", "idle")
  end

  # Returns job progress (0-100)
  def wizard_job_progress
    wizard_state.fetch("job_progress", 0)
  end

  # Returns error message or nil
  def wizard_job_error
    wizard_state.fetch("job_error", nil)
  end

  # Returns job metadata hash (total_items, processed_items, etc.)
  def wizard_job_metadata
    wizard_state.fetch("job_metadata", {})
  end

  # Returns true if wizard has been started but not completed
  def wizard_in_progress?
    wizard_state.fetch("started_at", nil).present? &&
      wizard_state.fetch("completed_at", nil).nil?
  end

  # Updates wizard job status atomically
  # @param status [String] 'idle', 'running', 'completed', 'failed'
  # @param progress [Integer] 0-100
  # @param error [String, nil] Error message
  # @param metadata [Hash] Additional job metadata
  def update_wizard_job_status(status:, progress: nil, error: nil, metadata: {})
    new_state = wizard_state.merge({
      "job_status" => status,
      "job_progress" => progress || wizard_job_progress,
      "job_error" => error,
      "job_metadata" => wizard_job_metadata.merge(metadata)
    })

    update!(wizard_state: new_state)
  end

  # Resets wizard to initial state
  def reset_wizard!
    update!(wizard_state: {
      "current_step" => 0,
      "started_at" => Time.current.iso8601,
      "completed_at" => nil,
      "job_status" => "idle",
      "job_progress" => 0,
      "job_error" => nil,
      "job_metadata" => {},
      "step_data" => {}
    })
  end
end
```

### Routes Configuration

**File**: `config/routes.rb`

Add under the `namespace :admin` block:

```ruby
namespace :admin do
  namespace :music do
    namespace :songs do
      resources :lists do
        # Wizard routes
        resource :wizard, only: [:show], controller: "list_wizard" do
          get "step/:step", action: :show_step, as: :step
          get "step/:step/status", action: :step_status, as: :step_status
          post "step/:step/advance", action: :advance_step, as: :advance_step
          post "step/:step/back", action: :back_step, as: :back_step
          post "restart", action: :restart
        end

        # List item action routes (to be implemented in [092])
        resources :items, controller: "list_items_actions", only: [] do
          member do
            post :verify
            post :skip
            patch :metadata
            post :re_enrich
            post :manual_link
            post :queue_import
          end

          collection do
            post :bulk_verify
            post :bulk_skip
            delete :bulk_delete
          end
        end
      end
    end
  end
end
```

**Generated Routes**:
```
GET    /admin/music/songs/lists/:list_id/wizard              → show
GET    /admin/music/songs/lists/:list_id/wizard/step/:step   → show_step
GET    /admin/music/songs/lists/:list_id/wizard/step/:step/status → step_status
POST   /admin/music/songs/lists/:list_id/wizard/step/:step/advance → advance_step
POST   /admin/music/songs/lists/:list_id/wizard/step/:step/back → back_step
POST   /admin/music/songs/lists/:list_id/wizard/restart      → restart
```

## Testing Strategy

### Migration Tests

**File**: `test/db/migrate/add_wizard_state_to_lists_test.rb`

```ruby
require "test_helper"

class AddWizardStateToListsTest < ActiveSupport::TestCase
  test "adds wizard_state column with default empty hash" do
    # Migration already run, verify column exists
    assert List.column_names.include?("wizard_state")
    assert_equal :jsonb, List.columns_hash["wizard_state"].type
  end

  test "default wizard_state is empty hash" do
    list = Music::Songs::List.create!(name: "Test List", type: "Music::Songs::List")
    assert_equal({}, list.wizard_state)
  end
end
```

### Model Helper Tests

**File**: `test/models/list_test.rb`

Add to existing test file:

```ruby
# === Wizard State Helpers ===

test "wizard_current_step returns 0 when wizard_state is empty" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {})
  assert_equal 0, list.wizard_current_step
end

test "wizard_current_step returns stored value" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {"current_step" => 3})
  assert_equal 3, list.wizard_current_step
end

test "wizard_job_status returns idle by default" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {})
  assert_equal "idle", list.wizard_job_status
end

test "wizard_job_status returns stored value" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {"job_status" => "running"})
  assert_equal "running", list.wizard_job_status
end

test "wizard_job_progress returns 0 by default" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {})
  assert_equal 0, list.wizard_job_progress
end

test "wizard_job_progress returns stored value" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {"job_progress" => 75})
  assert_equal 75, list.wizard_job_progress
end

test "wizard_job_error returns nil by default" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {})
  assert_nil list.wizard_job_error
end

test "wizard_job_error returns stored value" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {"job_error" => "Something went wrong"})
  assert_equal "Something went wrong", list.wizard_job_error
end

test "wizard_job_metadata returns empty hash by default" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {})
  assert_equal({}, list.wizard_job_metadata)
end

test "wizard_job_metadata returns stored value" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {"job_metadata" => {"total_items" => 100}})
  assert_equal({"total_items" => 100}, list.wizard_job_metadata)
end

test "wizard_in_progress? returns false when not started" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {})
  assert_not list.wizard_in_progress?
end

test "wizard_in_progress? returns true when started but not completed" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {"started_at" => Time.current.iso8601})
  assert list.wizard_in_progress?
end

test "wizard_in_progress? returns false when completed" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {
    "started_at" => 1.hour.ago.iso8601,
    "completed_at" => Time.current.iso8601
  })
  assert_not list.wizard_in_progress?
end

test "update_wizard_job_status merges new state" do
  list = lists(:music_songs_list)
  list.reset_wizard!

  list.update_wizard_job_status(
    status: "running",
    progress: 50,
    metadata: {total_items: 100}
  )

  assert_equal "running", list.wizard_job_status
  assert_equal 50, list.wizard_job_progress
  assert_equal({"total_items" => 100}, list.wizard_job_metadata)
end

test "update_wizard_job_status preserves existing metadata" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {"job_metadata" => {"total_items" => 100}})

  list.update_wizard_job_status(
    status: "running",
    metadata: {processed_items: 50}
  )

  expected = {"total_items" => 100, "processed_items" => 50}
  assert_equal expected, list.wizard_job_metadata
end

test "update_wizard_job_status preserves progress if not provided" do
  list = lists(:music_songs_list)
  list.update!(wizard_state: {"job_progress" => 30})

  list.update_wizard_job_status(status: "running")

  assert_equal 30, list.wizard_job_progress
end

test "reset_wizard! sets all initial values" do
  list = lists(:music_songs_list)
  list.reset_wizard!

  assert_equal 0, list.wizard_current_step
  assert_equal "idle", list.wizard_job_status
  assert_equal 0, list.wizard_job_progress
  assert_nil list.wizard_job_error
  assert_equal({}, list.wizard_job_metadata)
  assert_equal({}, list.wizard_state["step_data"])
  assert list.wizard_state["started_at"].present?
  assert_nil list.wizard_state["completed_at"]
end
```

### Route Tests

**File**: `test/routing/wizard_routes_test.rb`

```ruby
require "test_helper"

class WizardRoutesTest < ActionDispatch::IntegrationTest
  test "routes to wizard show" do
    assert_routing(
      {path: "/admin/music/songs/lists/1/wizard", method: :get},
      {controller: "admin/music/songs/list_wizard", action: "show", list_id: "1"}
    )
  end

  test "routes to wizard step" do
    assert_routing(
      {path: "/admin/music/songs/lists/1/wizard/step/enrich", method: :get},
      {controller: "admin/music/songs/list_wizard", action: "show_step", list_id: "1", step: "enrich"}
    )
  end

  test "routes to step status" do
    assert_routing(
      {path: "/admin/music/songs/lists/1/wizard/step/enrich/status", method: :get},
      {controller: "admin/music/songs/list_wizard", action: "step_status", list_id: "1", step: "enrich"}
    )
  end

  test "routes to advance step" do
    assert_routing(
      {path: "/admin/music/songs/lists/1/wizard/step/enrich/advance", method: :post},
      {controller: "admin/music/songs/list_wizard", action: "advance_step", list_id: "1", step: "enrich"}
    )
  end

  test "routes to back step" do
    assert_routing(
      {path: "/admin/music/songs/lists/1/wizard/step/enrich/back", method: :post},
      {controller: "admin/music/songs/list_wizard", action: "back_step", list_id: "1", step: "enrich"}
    )
  end

  test "routes to restart" do
    assert_routing(
      {path: "/admin/music/songs/lists/1/wizard/restart", method: :post},
      {controller: "admin/music/songs/list_wizard", action: "restart", list_id: "1"}
    )
  end
end
```

## Implementation Steps

1. **Create wizard_state migration**
   - Generate migration: `bin/rails g migration AddWizardStateToLists wizard_state:jsonb`
   - Edit migration to add default: `{}`
   - Run migration: `bin/rails db:migrate`

2. **Create indexes migration**
   - Generate migration: `bin/rails g migration AddWizardIndexesToListItems`
   - Add index statements
   - Run migration: `bin/rails db:migrate`

3. **Add helper methods to List model**
   - Open `app/models/list.rb`
   - Add all wizard helper methods
   - Test in Rails console

4. **Update routes**
   - Open `config/routes.rb`
   - Add wizard routes under `namespace :songs`
   - Verify routes: `bin/rails routes | grep wizard`

5. **Write tests**
   - Add model tests for all helper methods
   - Add route tests
   - Run tests: `bin/rails test`

## Dependencies

### Existing
- List model (`app/models/list.rb`)
- ListItem model (`app/models/list_item.rb`)
- Admin routes namespace
- Rails 8.0 JSONB support

### New (This Task)
- `wizard_state` JSONB column
- Wizard helper methods on List
- Wizard routes

### Needed Later
- Wizard controller ([087])
- Background jobs ([088], [089], [090])
- Service objects ([089], [092])

## Validation

- [ ] Migration runs without errors
- [ ] `List.column_names.include?("wizard_state")` returns true
- [ ] New list has `wizard_state == {}`
- [ ] All helper methods return safe defaults
- [ ] `update_wizard_job_status` updates database
- [ ] `reset_wizard!` sets correct initial values
- [ ] All tests pass
- [ ] Routes accessible via `bin/rails routes | grep wizard`

## Related Tasks

- **Next**: [087] Song Wizard UI Shell & Navigation
- **Depends On**: None (foundation task)
- **Reference**: `docs/todos/086-polling-approach-summary.md` for architecture decisions

## Implementation Notes

*To be filled during implementation*

## Deviations from Plan

*To be filled if implementation differs from spec*

## Documentation Updated

- [ ] This task file updated with implementation notes
- [ ] Model helper methods follow existing List conventions
- [ ] No inline documentation needed (methods are self-explanatory)
