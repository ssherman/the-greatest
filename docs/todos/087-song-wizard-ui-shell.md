# [087] - Song Wizard UI Shell & Navigation

## Status
- **Status**: Planned
- **Priority**: High
- **Created**: 2025-01-19
- **Started**: Not started
- **Completed**: Not completed
- **Developer**: AI + Human

## Overview
Build the wizard shell with navigation, progress indicators, and polling infrastructure. This provides the container and navigation framework that all wizard steps will use.

## Context

This is **Part 2 of 10** in the Song List Wizard implementation:

1. [086] Infrastructure ← Done
2. **[087] UI Shell & Navigation** ← You are here
3. [088] Step 0: Import Source Choice
4. [089] Step 1: Parse HTML
5. [090] Step 2: Enrich
6. [091] Step 3: Validation
7. [092] Step 4: Review UI
8. [093] Step 4: Actions
9. [094] Step 5: Import
10. [095] Polish & Integration

### What This Builds

- Wizard controller with step navigation
- Progress step indicator (visual breadcrumbs)
- Turbo Frame structure for step content
- Polling Stimulus controller for job status
- Wizard layout and shell views

### What This Does NOT Build

- Individual step content (covered in tasks 088-093)
- Background jobs (covered in tasks 088-090, 093)
- Service objects (covered in tasks 089, 092)

## Requirements

### Functional Requirements

#### FR-1: Wizard Controller
- [ ] `show` action - Redirects to current step
- [ ] `show_step` action - Renders specific step view
- [ ] `step_status` action - JSON endpoint for polling
- [ ] `advance_step` action - Moves to next step, enqueues job if needed
- [ ] `back_step` action - Returns to previous step
- [ ] `restart` action - Resets wizard state

#### FR-2: Step Navigation
- [ ] Can only advance when current step's job is completed
- [ ] Can go back to previous steps without restriction
- [ ] Back button disabled on first step
- [ ] Next button disabled when job is running
- [ ] Current step stored in wizard_state and persisted

#### FR-3: Progress Indicator
- [ ] Shows all 7 steps: Source → Parse → Enrich → Validate → Review → Import → Complete
- [ ] If MusicBrainz series chosen, skips steps 1-5 (Source → Import → Complete)
- [ ] Highlights completed steps
- [ ] Shows current step
- [ ] Shows upcoming steps (grayed out)
- [ ] Mobile responsive (stacks vertically)

#### FR-4: Polling Infrastructure
- [ ] Stimulus controller polls every 2 seconds
- [ ] Updates progress bar
- [ ] Updates status text
- [ ] Enables next button when job completes
- [ ] Shows error message if job fails
- [ ] Stops polling on disconnect or completion

#### FR-5: Wizard Layout
- [ ] Consistent header with list name
- [ ] Progress indicator at top
- [ ] Step content in Turbo Frame (no full page reload)
- [ ] Navigation buttons at bottom
- [ ] Mobile responsive design

### Non-Functional Requirements

#### NFR-1: Performance
- [ ] Step transitions < 200ms (Turbo Frame)
- [ ] Polling adds < 50ms overhead per request
- [ ] Progress indicator renders in < 100ms

#### NFR-2: Usability
- [ ] Clear visual feedback for disabled buttons
- [ ] Loading states during navigation
- [ ] Error messages are user-friendly

## Acceptance Criteria

### Controller
- [ ] Wizard controller exists at `Admin::Music::Songs::ListWizardController`
- [ ] All 6 actions implemented and tested
- [ ] Step validation prevents skipping steps
- [ ] Status endpoint returns JSON with job status
- [ ] Advancing step enqueues appropriate job (stub for now)

### Navigation
- [ ] Can navigate forward through steps
- [ ] Can navigate backward through steps
- [ ] Cannot skip ahead without completing jobs
- [ ] Current step persisted to database
- [ ] Restart resets to step 0

### Progress Indicator
- [ ] All 6 steps displayed
- [ ] Current step highlighted
- [ ] Completed steps shown with checkmark
- [ ] Renders correctly on mobile

### Polling
- [ ] Polling starts when step loads
- [ ] Polling stops when component disconnects
- [ ] Progress bar updates from polling data
- [ ] Next button enables when job completes
- [ ] Error shown if job fails

### Layout
- [ ] Wizard layout consistent across all steps
- [ ] Turbo Frame used for step content
- [ ] Mobile responsive

## Technical Approach

### Wizard Controller

**File**: `app/controllers/admin/music/songs/list_wizard_controller.rb`

```ruby
class Admin::Music::Songs::ListWizardController < Admin::Music::BaseController
  before_action :set_list
  before_action :initialize_wizard_state
  before_action :validate_step, only: [:show_step, :advance_step, :back_step]

  STEPS = %w[source parse enrich validate review import complete].freeze

  # GET /admin/music/songs/lists/:list_id/wizard
  def show
    current_step_name = STEPS[@list.wizard_current_step] || "source"
    redirect_to admin_music_songs_list_wizard_step_path(@list, current_step_name)
  end

  # GET /admin/music/songs/lists/:list_id/wizard/step/:step
  def show_step
    @step_name = params[:step]
    @step_index = STEPS.index(@step_name)

    # Load step-specific data (to be implemented in individual step tasks)
    case @step_name
    when "source"
      # Step 0: Choose import source (implemented in [088])
    when "parse"
      @items = @list.list_items.unverified.order(:position)
    when "enrich"
      @items = @list.list_items.unverified.order(:position)
      @stats = calculate_enrichment_stats(@items) if @items.any?
    when "validate"
      @items = @list.list_items.unverified
        .where("metadata->'mb_recording_id' IS NOT NULL")
        .order(:position)
      @stats = calculate_validation_stats(@items) if @items.any?
    when "review"
      @items = @list.list_items.unverified.order(:position).includes(:listable)
      @stats = calculate_review_stats(@items) if @items.any?
    when "import"
      @items_to_import = @list.list_items.unverified
        .where("metadata->>'wizard_queue_import' = 'true'")
        .where("metadata->'mb_recording_id' IS NOT NULL")
      @stats = calculate_import_stats(@list.list_items)
    when "complete"
      @stats = calculate_final_stats(@list.list_items)
    end

    render layout: "music/admin", turbo_frame: "wizard_step_content"
  end

  # GET /admin/music/songs/lists/:list_id/wizard/step/:step/status
  def step_status
    render json: {
      status: @list.wizard_job_status,
      progress: @list.wizard_job_progress,
      error: @list.wizard_job_error,
      metadata: @list.wizard_job_metadata
    }
  end

  # POST /admin/music/songs/lists/:list_id/wizard/step/:step/advance
  def advance_step
    current_index = STEPS.index(params[:step])

    # Enqueue appropriate job for this step (stubs for now, implemented in later tasks)
    case params[:step]
    when "source"
      # Check which import source was chosen
      import_source = params[:import_source]
      if import_source == "musicbrainz_series"
        # Skip to import step (step 5)
        new_wizard_state = @list.wizard_state.merge(
          "current_step" => 5,
          "import_source" => "musicbrainz_series"
        )
        @list.update!(wizard_state: new_wizard_state)
        return redirect_to admin_music_songs_list_wizard_step_path(@list, "import")
      else
        # Continue with custom HTML flow
        new_wizard_state = @list.wizard_state.merge("import_source" => "custom_html")
        @list.update!(wizard_state: new_wizard_state)
      end
    when "parse"
      enqueue_parsing_job
    when "enrich"
      enqueue_enrichment_job
    when "validate"
      enqueue_validation_job
    when "review"
      # No job needed, user manually reviewed items
    when "import"
      # Check import source to determine which job to enqueue
      if @list.wizard_state.dig("import_source") == "musicbrainz_series"
        enqueue_musicbrainz_series_import_job
      else
        enqueue_import_jobs
      end
    end

    # Update wizard state
    new_wizard_state = @list.wizard_state.merge("current_step" => current_index + 1)
    @list.update!(wizard_state: new_wizard_state)

    redirect_to admin_music_songs_list_wizard_step_path(@list, STEPS[current_index + 1])
  end

  # POST /admin/music/songs/lists/:list_id/wizard/step/:step/back
  def back_step
    current_index = STEPS.index(params[:step])
    return if current_index.zero?

    new_wizard_state = @list.wizard_state.merge("current_step" => current_index - 1)
    @list.update!(wizard_state: new_wizard_state)

    redirect_to admin_music_songs_list_wizard_step_path(@list, STEPS[current_index - 1])
  end

  # POST /admin/music/songs/lists/:list_id/wizard/restart
  def restart
    @list.reset_wizard!
    redirect_to admin_music_songs_list_wizard_step_path(@list, "parse")
  end

  private

  def set_list
    @list = Music::Songs::List.find(params[:list_id])
  end

  def initialize_wizard_state
    @list.reset_wizard! if @list.wizard_state.blank?
  end

  def validate_step
    unless STEPS.include?(params[:step])
      redirect_to admin_music_songs_list_wizard_path(@list),
        alert: "Invalid step: #{params[:step]}"
    end
  end

  # Job enqueue methods (stubs for now, implemented in later tasks)
  def enqueue_parsing_job
    # TODO: Implement in [089]
    Rails.logger.info "Would enqueue parsing job for list #{@list.id}"
  end

  def enqueue_enrichment_job
    # TODO: Implement in [090]
    Rails.logger.info "Would enqueue enrichment job for list #{@list.id}"
  end

  def enqueue_validation_job
    # TODO: Implement in [091]
    Rails.logger.info "Would enqueue validation job for list #{@list.id}"
  end

  def enqueue_import_jobs
    # TODO: Implement in [094]
    Rails.logger.info "Would enqueue import jobs for list #{@list.id}"
  end

  def enqueue_musicbrainz_series_import_job
    # TODO: Implement in [088]
    Rails.logger.info "Would enqueue MusicBrainz series import job for list #{@list.id}"
  end

  # Stats calculation methods (stubs for now, implemented in later tasks)
  def calculate_enrichment_stats(items)
    {}
  end

  def calculate_validation_stats(items)
    {}
  end

  def calculate_review_stats(items)
    {}
  end

  def calculate_import_stats(items)
    {}
  end

  def calculate_final_stats(items)
    {}
  end
end
```

### Wizard Shell View

**File**: `app/views/admin/music/songs/list_wizard/show_step.html.erb`

```erb
<div class="min-h-screen bg-base-200 p-4">
  <!-- Header -->
  <div class="mb-6">
    <h1 class="text-3xl font-bold"><%= @list.name %></h1>
    <p class="text-base-content/70">List Wizard</p>
  </div>

  <!-- Progress Steps -->
  <%= render "admin/music/songs/list_wizard/progress_steps",
      current_step: @step_index,
      list: @list %>

  <!-- Step Content (Turbo Frame) -->
  <div class="mt-8">
    <%= turbo_frame_tag "wizard_step_content" do %>
      <%= render "admin/music/songs/list_wizard/steps/#{@step_name}",
          list: @list,
          items: @items,
          stats: @stats %>
    <% end %>
  </div>
</div>
```

### Progress Steps Partial

**File**: `app/views/admin/music/songs/list_wizard/_progress_steps.html.erb`

```erb
<%
  list = local_assigns.fetch(:list)
  import_source = list.wizard_state.dig("import_source")

  # Full wizard steps (if custom HTML chosen)
  full_steps = [
    { name: "Source", icon: "🎯", step: "source" },
    { name: "Parse", icon: "📄", step: "parse" },
    { name: "Enrich", icon: "🔍", step: "enrich" },
    { name: "Validate", icon: "✓", step: "validate" },
    { name: "Review", icon: "👁", step: "review" },
    { name: "Import", icon: "⬇", step: "import" },
    { name: "Complete", icon: "🎉", step: "complete" }
  ]

  # Short wizard steps (if MusicBrainz series chosen)
  short_steps = [
    { name: "Source", icon: "🎯", step: "source" },
    { name: "Import", icon: "⬇", step: "import" },
    { name: "Complete", icon: "🎉", step: "complete" }
  ]

  # Use short steps if MusicBrainz series was chosen
  steps = import_source == "musicbrainz_series" ? short_steps : full_steps
  current_step = local_assigns.fetch(:current_step, 0)
%>

<ul class="steps steps-horizontal w-full">
  <% steps.each_with_index do |step_info, index| %>
    <li class="step <%= 'step-primary' if index <= current_step %>">
      <span class="text-lg mr-2"><%= step_info[:icon] %></span>
      <span class="hidden sm:inline"><%= step_info[:name] %></span>
    </li>
  <% end %>
</ul>
```

### Polling Stimulus Controller

**File**: `app/javascript/controllers/wizard_step_controller.js`

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    listId: Number,
    stepName: String,
    pollInterval: { type: Number, default: 2000 } // 2 seconds
  }

  static targets = ["progressBar", "statusText", "nextButton"]

  connect() {
    this.startPolling()
  }

  disconnect() {
    this.stopPolling()
  }

  startPolling() {
    this.poll()
  }

  stopPolling() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  poll() {
    this.pollTimer = setInterval(() => {
      this.checkJobStatus()
    }, this.pollIntervalValue)
  }

  async checkJobStatus() {
    try {
      const response = await fetch(
        `/admin/music/songs/lists/${this.listIdValue}/wizard/step/${this.stepNameValue}/status`
      )
      const data = await response.json()

      // Update progress bar
      this.updateProgress(data.progress, data.metadata)

      // If completed, enable next button and stop polling
      if (data.status === 'completed') {
        this.stopPolling()
        this.enableNextButton()
      }

      // If failed, show error and stop polling
      if (data.status === 'failed') {
        this.stopPolling()
        this.showError(data.error)
      }
    } catch (error) {
      console.error('Failed to check job status:', error)
      // Continue polling even on error
    }
  }

  updateProgress(percent, metadata) {
    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = `${percent}%`
      this.progressBarTarget.textContent = `${percent}%`
    }

    if (this.hasStatusTextTarget && metadata) {
      const processed = metadata.processed_items || 0
      const total = metadata.total_items || 0
      this.statusTextTarget.textContent = `Processing ${processed} of ${total} items...`
    }
  }

  enableNextButton() {
    if (this.hasNextButtonTarget) {
      this.nextButtonTarget.disabled = false
      this.nextButtonTarget.classList.remove('btn-disabled')
    }
  }

  showError(error) {
    const errorDiv = document.createElement('div')
    errorDiv.className = 'alert alert-error mt-4'
    errorDiv.innerHTML = `
      <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" />
      </svg>
      <span>${error}</span>
    `
    this.element.appendChild(errorDiv)
  }
}
```

### Step Template (Example)

**File**: `app/views/admin/music/songs/list_wizard/steps/_source.html.erb`

```erb
<%# This is a placeholder - full implementation in [088] %>

<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <h2 class="card-title">Choose Import Source</h2>

    <p class="text-base-content/70 mb-6">
      How would you like to import songs for this list?
    </p>

    <%= form_with url: advance_step_admin_music_songs_list_wizard_path(@list, step: "source"),
        method: :post do |f| %>

      <!-- Option 1: MusicBrainz Series (Fast Path) -->
      <label class="cursor-pointer">
        <div class="card bg-base-200 hover:bg-base-300 mb-4">
          <div class="card-body">
            <div class="flex items-start gap-4">
              <%= f.radio_button :import_source, "musicbrainz_series",
                  class: "radio radio-primary mt-1" %>
              <div class="flex-1">
                <h3 class="font-bold text-lg">MusicBrainz Series</h3>
                <p class="text-sm text-base-content/70">
                  Import from a curated MusicBrainz series (fastest, no manual review needed)
                </p>
              </div>
            </div>
          </div>
        </div>
      </label>

      <!-- Option 2: Custom HTML (Full Wizard) -->
      <label class="cursor-pointer">
        <div class="card bg-base-200 hover:bg-base-300 mb-6">
          <div class="card-body">
            <div class="flex items-start gap-4">
              <%= f.radio_button :import_source, "custom_html",
                  class: "radio radio-primary mt-1",
                  checked: true %>
              <div class="flex-1">
                <h3 class="font-bold text-lg">Custom HTML List</h3>
                <p class="text-sm text-base-content/70">
                  Parse HTML, enrich, validate, and review manually (full control)
                </p>
              </div>
            </div>
          </div>
        </div>
      </label>

      <!-- Submit Button -->
      <div class="card-actions justify-end">
        <%= f.submit "Continue →", class: "btn btn-primary" %>
      </div>
    <% end %>
  </div>
</div>
```

**File**: `app/views/admin/music/songs/list_wizard/steps/_parse.html.erb`

```erb
<%# This is a placeholder - full implementation in [089] %>

<div class="card bg-base-100 shadow-xl"
     data-controller="wizard-step"
     data-wizard-step-list-id-value="<%= @list.id %>"
     data-wizard-step-step-name-value="parse">

  <div class="card-body">
    <h2 class="card-title">Parse HTML into List Items</h2>

    <p class="text-base-content/70 mb-4">
      This step will parse the HTML from your list and create unverified list items.
    </p>

    <!-- Progress Bar -->
    <div class="w-full bg-base-300 rounded-full h-6 mb-4">
      <div class="bg-primary h-6 rounded-full transition-all duration-300 flex items-center justify-center text-primary-content text-sm"
           style="width: <%= @list.wizard_job_progress %>%"
           data-wizard-step-target="progressBar">
        <%= @list.wizard_job_progress %>%
      </div>
    </div>

    <!-- Status Text -->
    <p class="mb-4" data-wizard-step-target="statusText">
      <% if @list.wizard_job_metadata.present? %>
        Processing <%= @list.wizard_job_metadata['processed_items'] || 0 %>
        of <%= @list.wizard_job_metadata['total_items'] || 0 %> items...
      <% else %>
        Ready to parse HTML
      <% end %>
    </p>

    <!-- Navigation Buttons -->
    <div class="card-actions justify-between mt-6">
      <%= button_to "← Back",
          back_step_admin_music_songs_list_wizard_path(@list, step: "parse"),
          method: :post,
          class: "btn btn-outline",
          disabled: true %>

      <%= button_to "Start Parsing →",
          advance_step_admin_music_songs_list_wizard_path(@list, step: "parse"),
          method: :post,
          class: "btn btn-primary",
          disabled: @list.wizard_job_status == 'running',
          data: { wizard_step_target: 'nextButton' } %>
    </div>
  </div>
</div>
```

## Testing Strategy

### Controller Tests

**File**: `test/controllers/admin/music/songs/list_wizard_controller_test.rb`

```ruby
require "test_helper"

class Admin::Music::Songs::ListWizardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @list = lists(:music_songs_list)
    @list.reset_wizard!
    sign_in users(:admin_user)
  end

  test "show redirects to current step" do
    get admin_music_songs_list_wizard_path(@list)

    assert_redirected_to admin_music_songs_list_wizard_step_path(@list, "parse")
  end

  test "show_step renders parse step" do
    get admin_music_songs_list_wizard_step_path(@list, "parse")

    assert_response :success
    assert_select "h2", text: /Parse HTML/i
  end

  test "step_status returns JSON with job status" do
    @list.update_wizard_job_status(status: "running", progress: 50)

    get step_status_admin_music_songs_list_wizard_step_path(@list, "parse"),
      as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "running", json["status"]
    assert_equal 50, json["progress"]
  end

  test "advance_step moves to next step" do
    post advance_step_admin_music_songs_list_wizard_path(@list, step: "parse")

    @list.reload
    assert_equal 1, @list.wizard_current_step
    assert_redirected_to admin_music_songs_list_wizard_step_path(@list, "enrich")
  end

  test "back_step moves to previous step" do
    @list.update!(wizard_state: @list.wizard_state.merge("current_step" => 2))

    post back_step_admin_music_songs_list_wizard_path(@list, step: "validate")

    @list.reload
    assert_equal 1, @list.wizard_current_step
    assert_redirected_to admin_music_songs_list_wizard_step_path(@list, "enrich")
  end

  test "back_step does nothing on first step" do
    post back_step_admin_music_songs_list_wizard_path(@list, step: "parse")

    @list.reload
    assert_equal 0, @list.wizard_current_step
  end

  test "restart resets wizard state" do
    @list.update!(wizard_state: @list.wizard_state.merge("current_step" => 3))

    post restart_admin_music_songs_list_wizard_path(@list)

    @list.reload
    assert_equal 0, @list.wizard_current_step
    assert_redirected_to admin_music_songs_list_wizard_step_path(@list, "parse")
  end

  test "validate_step rejects invalid step names" do
    get admin_music_songs_list_wizard_step_path(@list, "invalid_step")

    assert_redirected_to admin_music_songs_list_wizard_path(@list)
    assert_match /invalid step/i, flash[:alert]
  end
end
```

### Component Tests

**File**: `test/components/wizard_progress_steps_test.rb`

```ruby
require "test_helper"

class WizardProgressStepsTest < ViewComponent::TestCase
  test "renders all 6 steps" do
    render_inline Admin::Music::Songs::ListWizard::ProgressStepsComponent.new(current_step: 0)

    assert_selector "li.step", count: 6
    assert_text "Parse"
    assert_text "Enrich"
    assert_text "Validate"
    assert_text "Review"
    assert_text "Import"
    assert_text "Complete"
  end

  test "highlights current and completed steps" do
    render_inline Admin::Music::Songs::ListWizard::ProgressStepsComponent.new(current_step: 2)

    # First 3 steps should be highlighted (0, 1, 2)
    assert_selector "li.step.step-primary", count: 3
  end
end
```

## Implementation Steps

1. **Create wizard controller**
   - Create file `app/controllers/admin/music/songs/list_wizard_controller.rb`
   - Implement all 6 actions
   - Add stub methods for job enqueuing
   - Add stub methods for stats calculation

2. **Create wizard views**
   - Create directory `app/views/admin/music/songs/list_wizard/`
   - Create `show_step.html.erb` (shell view)
   - Create `_progress_steps.html.erb` (progress indicator)
   - Create `steps/` subdirectory for individual step views

3. **Create placeholder step views**
   - Create `steps/_parse.html.erb` (placeholder)
   - Create `steps/_enrich.html.erb` (placeholder)
   - Create `steps/_validate.html.erb` (placeholder)
   - Create `steps/_review.html.erb` (placeholder)
   - Create `steps/_import.html.erb` (placeholder)
   - Create `steps/_complete.html.erb` (placeholder)

4. **Create polling Stimulus controller**
   - Create `app/javascript/controllers/wizard_step_controller.js`
   - Implement polling logic
   - Implement progress updates
   - Implement error handling

5. **Write tests**
   - Controller tests for all actions
   - Component tests for progress indicator
   - Manual testing of navigation flow

6. **Test in browser**
   - Navigate through all steps
   - Verify progress indicator updates
   - Verify back/forward navigation works
   - Verify restart works

## Dependencies

### Depends On
- [086] Infrastructure (wizard_state, routes, model helpers)

### Needed By
- [088] Step 1: Parse (uses wizard shell)
- [089] Step 2: Enrich (uses wizard shell)
- [090] Step 3: Validation (uses wizard shell)
- [091] Step 4: Review UI (uses wizard shell)
- [093] Step 5: Import (uses wizard shell)

## Validation

- [ ] Wizard controller exists and responds to all routes
- [ ] Can navigate to wizard from list show page
- [ ] Progress indicator renders correctly
- [ ] Can navigate forward through steps
- [ ] Can navigate backward through steps
- [ ] Status endpoint returns JSON
- [ ] Polling controller starts on connect
- [ ] Polling controller stops on disconnect
- [ ] All tests pass

## Related Tasks

- **Previous**: [086] Song Wizard Infrastructure
- **Next**: [088] Song Step 1: Parse
- **Reference**: `docs/todos/086-polling-approach-summary.md`

## Implementation Notes

*To be filled during implementation*

## Deviations from Plan

*To be filled if implementation differs from spec*

## Documentation Updated

- [ ] This task file updated with implementation notes
- [ ] Controller follows existing admin controller patterns
- [ ] Views follow DaisyUI component conventions
