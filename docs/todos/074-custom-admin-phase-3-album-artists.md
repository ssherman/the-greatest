# 074 - Custom Admin Interface - Phase 3: Album Artists (Join Table)

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-11-09
- **Started**: TBD
- **Completed**: TBD
- **Developer**: Claude Code (AI Agent)

## Overview
Implement custom admin interface for managing the Music::AlbumArtist join table, allowing users to add, edit, and remove artist associations from both album and artist show pages. This is the first join table admin interface and establishes patterns for future join table management (song_artists, credits, etc.).

**Important**: The autocomplete component created in this phase is a **global, reusable component** (not admin-specific) that can be used throughout the application for any autocomplete needs - admin features, public user features, list creation, search functionality, etc.

## Context
- **Phase 1 Complete**: Artists admin CRUD implemented (docs/todos/072-custom-admin-phase-1-artists.md)
- **Phase 2 Complete**: Albums admin CRUD implemented (docs/todos/073-custom-admin-phase-2-albums.md)
- **First Join Table**: Music::AlbumArtist is the first many-to-many join table to get admin interface
- **No Top-Level Menu**: Unlike artists/albums, album_artists doesn't get sidebar navigation
- **Dual Context**: Manageable from both artist show page and album show page
- **Autocomplete Required**: Large datasets (2000+ artists, 3000+ albums) require search-as-you-type
- **Reusable Component**: Autocomplete pattern will be used extensively in future phases

## Requirements

### Base Album Artist Management
- [x] No top-level routes or index page (managed contextually only)
- [ ] Modal-based interface for add/edit/delete operations
- [ ] Context-aware pre-population (artist OR album, depending on parent page)
- [ ] Position management via modal form input
- [ ] Validation preventing duplicate artist-album pairs

### Album Show Page Integration
- [ ] "Add Artist" button opens create modal
- [ ] Create modal: album field pre-populated (disabled), artist autocomplete, position input
- [ ] Edit links open edit modal with all fields populated
- [ ] Edit modal: album field disabled, artist field disabled, position input enabled
- [ ] Delete confirmation for removing artists
- [ ] Real-time updates via Turbo Streams
- [ ] Display artists in position order with edit/delete actions

### Artist Show Page Integration
- [ ] "Add Album" button opens create modal
- [ ] Create modal: artist field pre-populated (disabled), album autocomplete, position input
- [ ] Edit links open edit modal with all fields populated
- [ ] Edit modal: artist field disabled, album field disabled, position input enabled
- [ ] Delete confirmation for removing albums
- [ ] Real-time updates via Turbo Streams
- [ ] Display albums in position order with edit/delete actions

### Autocomplete System
- [ ] Reusable autocomplete ViewComponent
- [ ] Reusable autocomplete Stimulus controller
- [ ] Integration with existing search endpoints
- [ ] Uses autoComplete.js library (v10.2.9)
- [ ] Debounced search (300ms)
- [ ] Minimum 2 characters to trigger search
- [ ] Styled with DaisyUI components
- [ ] Accessible (WAI-ARIA compliant)
- [ ] Displays album title + artist names for album autocomplete
- [ ] Displays artist name for artist autocomplete

## Technical Approach

### 1. Routing & Controllers

```ruby
# config/routes.rb

# Inside Music domain constraint
constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
  namespace :admin, module: "admin/music" do
    root to: "dashboard#index"

    resources :artists do
      # Nested album_artists routes
      resources :album_artists, only: [:create, :update, :destroy], shallow: true
    end

    resources :albums do
      # Nested album_artists routes
      resources :album_artists, only: [:create, :update, :destroy], shallow: true
    end
  end
end
```

**Generated paths**:
- `admin_artist_album_artists_path(@artist)` → POST `/admin/artists/:artist_id/album_artists`
- `admin_album_album_artists_path(@album)` → POST `/admin/albums/:album_id/album_artists`
- `admin_album_artist_path(@album_artist)` → PATCH/DELETE `/admin/album_artists/:id`

**Note**: Using `shallow: true` prevents deeply nested routes for update/destroy actions.

### 2. Controller Architecture

```ruby
# app/controllers/admin/music/album_artists_controller.rb
class Admin::Music::AlbumArtistsController < Admin::Music::BaseController
  before_action :set_album_artist, only: [:update, :destroy]
  before_action :set_parent_context, only: [:create]

  def create
    @album_artist = Music::AlbumArtist.new(album_artist_params)

    if @album_artist.save
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: { flash: { notice: "Artist association added successfully." } }
            ),
            turbo_stream.replace(
              turbo_frame_id,
              partial: partial_path,
              locals: partial_locals
            )
          ]
        end
        format.html do
          redirect_to redirect_path, notice: "Artist association added successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: { flash: { error: @album_artist.errors.full_messages.join(", ") } }
          )
        end
        format.html do
          redirect_to redirect_path, alert: @album_artist.errors.full_messages.join(", ")
        end
      end
    end
  end

  def update
    if @album_artist.update(album_artist_params)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: { flash: { notice: "Position updated successfully." } }
            ),
            turbo_stream.replace(
              turbo_frame_id,
              partial: partial_path,
              locals: partial_locals
            )
          ]
        end
        format.html do
          redirect_to redirect_path, notice: "Position updated successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: { flash: { error: @album_artist.errors.full_messages.join(", ") } }
          )
        end
        format.html do
          redirect_to redirect_path, alert: @album_artist.errors.full_messages.join(", ")
        end
      end
    end
  end

  def destroy
    @album_artist.destroy!

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: { flash: { notice: "Artist association removed successfully." } }
          ),
          turbo_stream.replace(
            turbo_frame_id,
            partial: partial_path,
            locals: partial_locals
          )
        ]
      end
      format.html do
        redirect_to redirect_path, notice: "Artist association removed successfully."
      end
    end
  end

  private

  def set_album_artist
    @album_artist = Music::AlbumArtist.find(params[:id])
  end

  def set_parent_context
    # Determine parent context from params
    if params[:album_id].present?
      @album = Music::Album.find(params[:album_id])
      @context = :album
    elsif params[:artist_id].present?
      @artist = Music::Artist.find(params[:artist_id])
      @context = :artist
    end
  end

  def album_artist_params
    params.require(:music_album_artist).permit(:album_id, :artist_id, :position)
  end

  def redirect_path
    if @album_artist.album
      admin_album_path(@album_artist.album)
    elsif @album_artist.artist
      admin_artist_path(@album_artist.artist)
    else
      admin_root_path
    end
  end

  def turbo_frame_id
    @context == :album ? "album_artists_list" : "artist_albums_list"
  end

  def partial_path
    @context == :album ? "admin/music/albums/artists_list" : "admin/music/artists/albums_list"
  end

  def partial_locals
    if @context == :album
      { album: @album }
    else
      { artist: @artist }
    end
  end
end
```

**Key aspects**:
- Context-aware (knows if called from album or artist page)
- Turbo Stream responses for dynamic updates
- Determines redirect path based on parent resource
- Reloads appropriate partial after create/update/destroy
- Updates flash messages via Turbo Stream

### 3. Autocomplete ViewComponent

**Note**: This is a **global component** (not admin-specific) that can be reused across the entire application for any autocomplete needs (admin, public user features, list creation, etc.).

```ruby
# app/components/autocomplete_component.rb
class AutocompleteComponent < ViewComponent::Base
  def initialize(
    name:,
    url:,
    placeholder: "Search...",
    value: nil,
    selected_text: nil,
    display_key: "text",
    value_key: "value",
    min_length: 2,
    debounce: 300,
    required: false,
    disabled: false
  )
    @name = name
    @url = url
    @placeholder = placeholder
    @value = value
    @selected_text = selected_text
    @display_key = display_key
    @value_key = value_key
    @min_length = min_length
    @debounce = debounce
    @required = required
    @disabled = disabled
  end

  def input_id
    @name.to_s.gsub(/[\[\]]/, "_").squeeze("_").sub(/_$/, "")
  end

  def autocomplete_id
    "#{input_id}_autocomplete"
  end

  private

  attr_reader :name, :url, :placeholder, :value, :selected_text,
              :display_key, :value_key, :min_length, :debounce,
              :required, :disabled
end
```

```erb
<!-- app/components/autocomplete_component/autocomplete_component.html.erb -->
<div data-controller="autocomplete"
     data-autocomplete-url-value="<%= url %>"
     data-autocomplete-min-length-value="<%= min_length %>"
     data-autocomplete-debounce-value="<%= debounce %>"
     data-autocomplete-display-key-value="<%= display_key %>"
     data-autocomplete-value-key-value="<%= value_key %>"
     class="form-control">

  <!-- Hidden field stores selected ID -->
  <%= hidden_field_tag name, value,
      data: { autocomplete_target: "hiddenField" },
      required: required %>

  <!-- Visible autocomplete input -->
  <input type="search"
         id="<%= autocomplete_id %>"
         data-autocomplete-target="input"
         value="<%= selected_text %>"
         placeholder="<%= placeholder %>"
         class="input input-bordered w-full <%= 'input-disabled' if disabled %>"
         autocomplete="off"
         <%= 'disabled' if disabled %>>

  <label class="label">
    <span class="label-text-alt">Start typing to search (min <%= min_length %> characters)</span>
  </label>
</div>
```

**Key aspects**:
- Reusable across all autocomplete needs
- Separate hidden field for ID, visible field for search/display
- Configurable search parameters
- DaisyUI styling
- Disabled state support for read-only fields
- Stimulus controller integration

### 4. Autocomplete Stimulus Controller

**Note**: This is a **global controller** (not admin-specific) registered as `autocomplete` for use throughout the application.

```javascript
// app/javascript/controllers/autocomplete_controller.js
import { Controller } from "@hotwired/stimulus"
import autoComplete from "@tarekraafat/autocomplete.js"

// Connects to data-controller="autocomplete"
export default class extends Controller {
  static targets = ["input", "hiddenField"]
  static values = {
    url: String,
    minLength: { type: Number, default: 2 },
    debounce: { type: Number, default: 300 },
    displayKey: { type: String, default: "text" },
    valueKey: { type: String, default: "value" }
  }

  connect() {
    this.abortController = null
    this.initAutoComplete()
  }

  disconnect() {
    if (this.autoComplete) {
      this.autoComplete = null
    }
    if (this.abortController) {
      this.abortController.abort()
    }
  }

  initAutoComplete() {
    this.autoComplete = new autoComplete({
      selector: () => this.inputTarget,
      placeHolder: this.inputTarget.placeholder,
      threshold: this.minLengthValue,
      debounce: this.debounceValue,

      data: {
        src: async () => {
          // Cancel previous request
          if (this.abortController) {
            this.abortController.abort()
          }

          this.abortController = new AbortController()

          try {
            const query = this.inputTarget.value
            const response = await fetch(
              `${this.urlValue}?q=${encodeURIComponent(query)}`,
              {
                signal: this.abortController.signal,
                headers: {
                  'Accept': 'application/json',
                  'X-CSRF-Token': this.csrfToken
                }
              }
            )

            if (!response.ok) {
              throw new Error(`HTTP error! status: ${response.status}`)
            }

            return await response.json()
          } catch (error) {
            if (error.name === 'AbortError') {
              return []
            }
            console.error('Autocomplete fetch error:', error)
            return []
          }
        },
        keys: [this.displayKeyValue],
        cache: false
      },

      resultsList: {
        tag: "ul",
        class: "dropdown-content menu p-2 shadow-lg bg-base-100 rounded-box w-full mt-1 max-h-80 overflow-y-auto z-50",
        maxResults: 10,
        noResults: true,
        element: (list, data) => {
          if (!data.results.length) {
            const message = document.createElement("div")
            message.className = "p-4 text-sm text-gray-500 text-center"
            message.textContent = `No results found for "${data.query}"`
            list.prepend(message)
          }
        }
      },

      resultItem: {
        tag: "li",
        class: "rounded-lg hover:bg-base-200 active:bg-base-300 cursor-pointer transition-colors px-4 py-2",
        highlight: {
          class: "text-primary font-semibold"
        },
        selected: "bg-base-200"
      },

      events: {
        input: {
          selection: (event) => {
            const selection = event.detail.selection.value

            // Update visible input with display text
            this.inputTarget.value = selection[this.displayKeyValue]

            // Update hidden field with ID value
            this.hiddenFieldTarget.value = selection[this.valueKeyValue]

            // Dispatch custom event for other controllers to listen to
            this.element.dispatchEvent(
              new CustomEvent('autocomplete:selected', {
                detail: { item: selection },
                bubbles: true
              })
            )
          },

          focus: () => {
            // Reopen results if input has value
            if (this.inputTarget.value.length >= this.minLengthValue) {
              this.autoComplete.start()
            }
          }
        }
      }
    })
  }

  get csrfToken() {
    return document.querySelector('[name="csrf-token"]')?.content || ''
  }
}
```

**Key aspects**:
- Uses autoComplete.js v10.2.9 (already installed via yarn/npm)
- Implements AbortController for request cancellation
- DaisyUI styling for results dropdown
- CSRF token handling for Rails
- Custom event dispatch for inter-controller communication
- Error handling for network failures
- Focus behavior to reopen results

**Installation**:
```bash
# Already installed in package.json
yarn add @tarekraafat/autocomplete.js
```

### 5. Album Show Page - Artists Section

```erb
<!-- app/views/admin/music/albums/show.html.erb -->

<!-- Add this section after existing sections -->
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <div class="flex justify-between items-center mb-4">
      <h2 class="card-title">
        Artists
        <div class="badge badge-primary"><%= @album.album_artists.count %></div>
      </h2>

      <button class="btn btn-primary btn-sm"
              onclick="add_artist_modal.showModal()">
        + Add Artist
      </button>
    </div>

    <%= turbo_frame_tag "album_artists_list" do %>
      <%= render "artists_list", album: @album %>
    <% end %>
  </div>
</div>

<!-- Add Artist Modal -->
<dialog id="add_artist_modal" class="modal">
  <div class="modal-box max-w-2xl">
    <h3 class="font-bold text-lg">Add Artist to Album</h3>
    <p class="py-4 text-sm text-gray-500">
      Search for an artist to associate with this album. You can set the position to control artist ordering.
    </p>

    <%= form_with model: Music::AlbumArtist.new,
                  url: admin_album_album_artists_path(@album),
                  method: :post,
                  class: "space-y-4" do |f| %>

      <!-- Album (pre-filled, disabled) -->
      <div class="form-control">
        <%= f.label :album_id, "Album", class: "label" do %>
          <span class="label-text font-semibold">Album</span>
        <% end %>
        <%= f.text_field :album_id,
            value: @album.title,
            disabled: true,
            class: "input input-bordered input-disabled w-full" %>
        <%= f.hidden_field :album_id, value: @album.id %>
      </div>

      <!-- Artist (autocomplete) -->
      <div class="form-control">
        <%= f.label :artist_id, "Artist", class: "label" do %>
          <span class="label-text font-semibold">Artist <span class="text-error">*</span></span>
        <% end %>
        <%= render AutocompleteComponent.new(
          name: "music_album_artist[artist_id]",
          url: search_admin_artists_path,
          placeholder: "Search for artist...",
          required: true
        ) %>
      </div>

      <!-- Position -->
      <div class="form-control">
        <%= f.label :position, class: "label" do %>
          <span class="label-text font-semibold">Position</span>
        <% end %>
        <%= f.number_field :position,
            value: @album.album_artists.maximum(:position).to_i + 1,
            min: 1,
            class: "input input-bordered w-full",
            required: true %>
        <label class="label">
          <span class="label-text-alt">Position in artist ordering (1 = first artist)</span>
        </label>
      </div>

      <div class="modal-action">
        <button type="button" class="btn" onclick="add_artist_modal.close()">Cancel</button>
        <%= f.submit "Add Artist", class: "btn btn-primary" %>
      </div>
    <% end %>
  </div>
  <form method="dialog" class="modal-backdrop">
    <button>close</button>
  </form>
</dialog>
```

**Artists List Partial**:
```erb
<!-- app/views/admin/music/albums/_artists_list.html.erb -->
<% if album.album_artists.any? %>
  <div class="overflow-x-auto">
    <table class="table table-zebra">
      <thead>
        <tr>
          <th>Position</th>
          <th>Artist</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody>
        <% album.album_artists.ordered.includes(:artist).each do |album_artist| %>
          <tr>
            <td>
              <span class="badge badge-sm"><%= album_artist.position %></span>
            </td>
            <td>
              <%= link_to album_artist.artist.name,
                  admin_artist_path(album_artist.artist),
                  class: "link link-hover",
                  data: { turbo_frame: "_top" } %>
            </td>
            <td>
              <div class="flex gap-2">
                <button class="btn btn-ghost btn-sm"
                        onclick="edit_album_artist_<%= album_artist.id %>_modal.showModal()">
                  Edit
                </button>
                <%= button_to "Remove",
                    admin_album_artist_path(album_artist),
                    method: :delete,
                    class: "btn btn-ghost btn-sm text-error",
                    data: {
                      turbo_confirm: "Remove #{album_artist.artist.name} from this album?",
                      turbo_frame: "album_artists_list"
                    } %>
              </div>
            </td>
          </tr>

          <!-- Edit Modal for this album_artist -->
          <dialog id="edit_album_artist_<%= album_artist.id %>_modal" class="modal">
            <div class="modal-box max-w-2xl">
              <h3 class="font-bold text-lg">Edit Artist Position</h3>
              <p class="py-4 text-sm text-gray-500">
                Update the position for this artist on the album.
              </p>

              <%= form_with model: album_artist,
                            url: admin_album_artist_path(album_artist),
                            method: :patch,
                            class: "space-y-4",
                            data: { turbo_frame: "album_artists_list" } do |f| %>

                <!-- Album (disabled) -->
                <div class="form-control">
                  <%= f.label :album_id, "Album", class: "label" do %>
                    <span class="label-text font-semibold">Album</span>
                  <% end %>
                  <%= f.text_field :album_id,
                      value: album.title,
                      disabled: true,
                      class: "input input-bordered input-disabled w-full" %>
                </div>

                <!-- Artist (disabled) -->
                <div class="form-control">
                  <%= f.label :artist_id, "Artist", class: "label" do %>
                    <span class="label-text font-semibold">Artist</span>
                  <% end %>
                  <%= f.text_field :artist_id,
                      value: album_artist.artist.name,
                      disabled: true,
                      class: "input input-bordered input-disabled w-full" %>
                </div>

                <!-- Position (editable) -->
                <div class="form-control">
                  <%= f.label :position, class: "label" do %>
                    <span class="label-text font-semibold">Position <span class="text-error">*</span></span>
                  <% end %>
                  <%= f.number_field :position,
                      value: album_artist.position,
                      min: 1,
                      class: "input input-bordered w-full",
                      required: true %>
                  <label class="label">
                    <span class="label-text-alt">Position in artist ordering (1 = first artist)</span>
                  </label>
                </div>

                <div class="modal-action">
                  <button type="button"
                          class="btn"
                          onclick="edit_album_artist_<%= album_artist.id %>_modal.close()">
                    Cancel
                  </button>
                  <%= f.submit "Update Position", class: "btn btn-primary" %>
                </div>
              <% end %>
            </div>
            <form method="dialog" class="modal-backdrop">
              <button>close</button>
            </form>
          </dialog>
        <% end %>
      </tbody>
    </table>
  </div>
<% else %>
  <p class="text-gray-500 text-sm">No artists associated with this album yet.</p>
<% end %>
```

### 6. Artist Show Page - Albums Section

```erb
<!-- app/views/admin/music/artists/show.html.erb -->

<!-- Add this section after existing sections -->
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <div class="flex justify-between items-center mb-4">
      <h2 class="card-title">
        Albums
        <div class="badge badge-primary"><%= @artist.album_artists.count %></div>
      </h2>

      <button class="btn btn-primary btn-sm"
              onclick="add_album_modal.showModal()">
        + Add Album
      </button>
    </div>

    <%= turbo_frame_tag "artist_albums_list" do %>
      <%= render "albums_list", artist: @artist %>
    <% end %>
  </div>
</div>

<!-- Add Album Modal -->
<dialog id="add_album_modal" class="modal">
  <div class="modal-box max-w-2xl">
    <h3 class="font-bold text-lg">Add Album to Artist</h3>
    <p class="py-4 text-sm text-gray-500">
      Search for an album to associate with this artist. You can set the position for multi-artist albums.
    </p>

    <%= form_with model: Music::AlbumArtist.new,
                  url: admin_artist_album_artists_path(@artist),
                  method: :post,
                  class: "space-y-4" do |f| %>

      <!-- Artist (pre-filled, disabled) -->
      <div class="form-control">
        <%= f.label :artist_id, "Artist", class: "label" do %>
          <span class="label-text font-semibold">Artist</span>
        <% end %>
        <%= f.text_field :artist_id,
            value: @artist.name,
            disabled: true,
            class: "input input-bordered input-disabled w-full" %>
        <%= f.hidden_field :artist_id, value: @artist.id %>
      </div>

      <!-- Album (autocomplete) -->
      <div class="form-control">
        <%= f.label :album_id, "Album", class: "label" do %>
          <span class="label-text font-semibold">Album <span class="text-error">*</span></span>
        <% end %>
        <%= render AutocompleteComponent.new(
          name: "music_album_artist[album_id]",
          url: search_admin_albums_path,
          placeholder: "Search for album...",
          required: true
        ) %>
      </div>

      <!-- Position -->
      <div class="form-control">
        <%= f.label :position, class: "label" do %>
          <span class="label-text font-semibold">Position</span>
        <% end %>
        <%= f.number_field :position,
            value: 1,
            min: 1,
            class: "input input-bordered w-full",
            required: true %>
        <label class="label">
          <span class="label-text-alt">Position for multi-artist albums (1 = primary artist)</span>
        </label>
      </div>

      <div class="modal-action">
        <button type="button" class="btn" onclick="add_album_modal.close()">Cancel</button>
        <%= f.submit "Add Album", class: "btn btn-primary" %>
      </div>
    <% end %>
  </div>
  <form method="dialog" class="modal-backdrop">
    <button>close</button>
  </form>
</dialog>
```

**Albums List Partial**:
```erb
<!-- app/views/admin/music/artists/_albums_list.html.erb -->
<% if artist.album_artists.any? %>
  <div class="overflow-x-auto">
    <table class="table table-zebra">
      <thead>
        <tr>
          <th>Position</th>
          <th>Album</th>
          <th>Release Year</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody>
        <% artist.album_artists.ordered.includes(:album).each do |album_artist| %>
          <tr>
            <td>
              <span class="badge badge-sm"><%= album_artist.position %></span>
            </td>
            <td>
              <%= link_to album_artist.album.title,
                  admin_album_path(album_artist.album),
                  class: "link link-hover",
                  data: { turbo_frame: "_top" } %>
            </td>
            <td><%= album_artist.album.release_year %></td>
            <td>
              <div class="flex gap-2">
                <button class="btn btn-ghost btn-sm"
                        onclick="edit_artist_album_<%= album_artist.id %>_modal.showModal()">
                  Edit
                </button>
                <%= button_to "Remove",
                    admin_album_artist_path(album_artist),
                    method: :delete,
                    class: "btn btn-ghost btn-sm text-error",
                    data: {
                      turbo_confirm: "Remove #{album_artist.album.title} from this artist?",
                      turbo_frame: "artist_albums_list"
                    } %>
              </div>
            </td>
          </tr>

          <!-- Edit Modal for this album_artist -->
          <dialog id="edit_artist_album_<%= album_artist.id %>_modal" class="modal">
            <div class="modal-box max-w-2xl">
              <h3 class="font-bold text-lg">Edit Album Position</h3>
              <p class="py-4 text-sm text-gray-500">
                Update the position for this album by the artist.
              </p>

              <%= form_with model: album_artist,
                            url: admin_album_artist_path(album_artist),
                            method: :patch,
                            class: "space-y-4",
                            data: { turbo_frame: "artist_albums_list" } do |f| %>

                <!-- Artist (disabled) -->
                <div class="form-control">
                  <%= f.label :artist_id, "Artist", class: "label" do %>
                    <span class="label-text font-semibold">Artist</span>
                  <% end %>
                  <%= f.text_field :artist_id,
                      value: artist.name,
                      disabled: true,
                      class: "input input-bordered input-disabled w-full" %>
                </div>

                <!-- Album (disabled) -->
                <div class="form-control">
                  <%= f.label :album_id, "Album", class: "label" do %>
                    <span class="label-text font-semibold">Album</span>
                  <% end %>
                  <%= f.text_field :album_id,
                      value: album_artist.album.title,
                      disabled: true,
                      class: "input input-bordered input-disabled w-full" %>
                </div>

                <!-- Position (editable) -->
                <div class="form-control">
                  <%= f.label :position, class: "label" do %>
                    <span class="label-text font-semibold">Position <span class="text-error">*</span></span>
                  <% end %>
                  <%= f.number_field :position,
                      value: album_artist.position,
                      min: 1,
                      class: "input input-bordered w-full",
                      required: true %>
                  <label class="label">
                    <span class="label-text-alt">Position for multi-artist albums (1 = primary artist)</span>
                  </label>
                </div>

                <div class="modal-action">
                  <button type="button"
                          class="btn"
                          onclick="edit_artist_album_<%= album_artist.id %>_modal.close()">
                    Cancel
                  </button>
                  <%= f.submit "Update Position", class: "btn btn-primary" %>
                </div>
              <% end %>
            </div>
            <form method="dialog" class="modal-backdrop">
              <button>close</button>
            </form>
          </dialog>
        <% end %>
      </tbody>
    </table>
  </div>
<% else %>
  <p class="text-gray-500 text-sm">No albums associated with this artist yet.</p>
<% end %>
```

### 7. Enhanced Controller with Eager Loading

Update artist and album show actions to eager load album_artists:

```ruby
# app/controllers/admin/music/artists_controller.rb
def show
  @artist = Music::Artist
    .includes(
      :categories,
      :identifiers,
      :primary_image,
      album_artists: { album: [:primary_image] },  # Enhanced eager loading
      images: []
    )
    .find(params[:id])
end
```

```ruby
# app/controllers/admin/music/albums_controller.rb
def show
  @album = Music::Album
    .includes(
      :categories,
      :identifiers,
      :primary_image,
      :external_links,
      album_artists: [:artist],  # Enhanced eager loading
      releases: [:primary_image],
      images: [],
      credits: [:artist]
    )
    .find(params[:id])
end
```

## Dependencies
- **Existing**: Tailwind CSS, DaisyUI, ViewComponents, Hotwire (Turbo + Stimulus), OpenSearch
- **Phase 1 Complete**: Artist admin with search endpoints
- **Phase 2 Complete**: Album admin with search endpoints
- **New Library**: autoComplete.js v10.2.9 (via CDN/importmap)
- **Existing Models**: Music::AlbumArtist, Music::Album, Music::Artist

## Acceptance Criteria
- [ ] Autocomplete component is reusable across different resources
- [ ] Add artist modal on album show page works correctly
- [ ] Add album modal on artist show page works correctly
- [ ] Edit modal on album show page updates position correctly
- [ ] Edit modal on artist show page updates position correctly
- [ ] Album/artist field is pre-populated and disabled based on context
- [ ] Autocomplete searches existing artists/albums via OpenSearch
- [ ] Position field defaults to next available position
- [ ] Edit modals show both album and artist (disabled) plus editable position
- [ ] Delete confirmation prevents accidental removals
- [ ] Turbo Stream updates refresh lists without full page reload
- [ ] Modals close automatically after successful save
- [ ] Duplicate artist-album pairs are prevented with validation
- [ ] Artists display in position order on album show page
- [ ] Albums display in position order on artist show page
- [ ] No N+1 queries (eager loading implemented)
- [ ] Autocomplete is accessible (WAI-ARIA compliant)
- [ ] Autocomplete is styled with DaisyUI
- [ ] All pages are responsive (mobile, tablet, desktop)
- [ ] Authorization prevents non-admin/editor access
- [ ] All tests passing with >95% coverage

## Design Decisions

### Why Modal-Based Instead of Separate Page
- **Context Preservation**: Keeps user on parent resource (album or artist)
- **Better UX**: No navigation required, instant feedback
- **Turbo Stream Compatible**: Updates list without full reload
- **Follows Phase 2 Pattern**: Merge album modal established this pattern

### Why autoComplete.js Over Alternatives
- **Lightweight**: 1.5kB - 9kB (vs stimulus-autocomplete at ~20kB)
- **Zero Dependencies**: Pure vanilla JavaScript
- **WAI-ARIA Compliant**: Built-in accessibility (v10.2.9)
- **DaisyUI Compatible**: Easy to style with Tailwind classes
- **Active Maintenance**: Latest release v10.2.9, Apache 2.0 license
- **Event Lifecycle**: Rich event system for Stimulus integration
- **Debounce Built-in**: No additional libraries needed

**Alternatives Considered**:
- **stimulus-autocomplete**: More opinionated, less flexible styling
- **hotwire_combobox**: Rails gem, but heavier and less customizable
- **Algolia Autocomplete**: Overkill for this use case, requires account

### Why Reusable Component Pattern
- **Future Proof**: Will be used for song_artists, credits, tracks, etc.
- **Consistency**: Same autocomplete behavior across admin
- **Maintainability**: Bug fixes apply to all autocomplete instances
- **Testability**: Test once, use everywhere

### Why Modal for Both Create and Edit
- **Consistency**: Same UX pattern for both create and edit operations
- **Full Context**: Shows both album and artist (disabled) plus editable position
- **Clear Intent**: User explicitly confirms changes with Save/Cancel buttons
- **Better for Complex Forms**: Easier to add validation feedback and help text
- **Follows Phase 2 Pattern**: Merge album modal established this successful pattern

### Why Nested Routes with Shallow Option
- **RESTful**: Follows Rails conventions for nested resources
- **Context-Aware**: Create knows parent resource from URL
- **Clean URLs**: Update/destroy don't need parent in URL
- **Standard Pattern**: Widely understood by Rails developers

### Why No Drag-and-Drop (Yet)
- **Complexity**: Requires additional JavaScript library (Sortable.js)
- **Accessibility**: Keyboard navigation is harder with drag-and-drop
- **Mobile**: Touch events add complexity
- **Future Enhancement**: Can be added in Phase 4+ if needed

## Acceptance Criteria for Testing

### Controller Tests Required

```ruby
# test/controllers/admin/music/album_artists_controller_test.rb

class Admin::Music::AlbumArtistsControllerTest < ActionDispatch::IntegrationTest
  # Create tests (4 tests)
  test "should create album_artist from album context"
  test "should create album_artist from artist context"
  test "should not create duplicate album_artist"
  test "should return turbo stream on create"

  # Update tests (3 tests)
  test "should update album_artist position"
  test "should not update with invalid position"
  test "should return turbo stream on update"

  # Destroy tests (2 tests)
  test "should destroy album_artist"
  test "should return turbo stream on destroy"

  # Authorization tests (2 tests)
  test "should require admin or editor role"
  test "should redirect non-admin users to root"

  # Context tests (2 tests)
  test "should determine context from album_id param"
  test "should determine context from artist_id param"

  # Total: ~13 tests
end
```

### Component Tests Required

```ruby
# test/components/autocomplete_component_test.rb

class AutocompleteComponentTest < ViewComponent::TestCase
  test "renders autocomplete input with correct attributes"
  test "renders hidden field for value storage"
  test "renders with disabled state"
  test "renders with custom placeholder"
  test "renders with required attribute"
  test "sets correct stimulus data attributes"

  # Total: 6 tests
end
```

### Stimulus Controller Tests (JavaScript)

```javascript
// test/javascript/controllers/autocomplete_controller.test.js

import { Application } from "@hotwired/stimulus"
import AutocompleteController from "../../app/javascript/controllers/autocomplete_controller"

// Setup tests
describe("AutocompleteController", () => {
  test("initializes autoComplete on connect")
  test("fetches results from configured URL")
  test("updates hidden field on selection")
  test("dispatches custom event on selection")
  test("handles empty results gracefully")
  test("cancels previous requests with AbortController")
  test("cleans up on disconnect")

  // Total: 7 tests
})
```

### Integration/System Tests (Optional, Recommended)

```ruby
# test/system/admin/album_artists_test.rb

class Admin::AlbumArtistsTest < ApplicationSystemTestCase
  test "admin can add artist to album via modal"
  test "admin can add album to artist via modal"
  test "admin can update position inline"
  test "admin can remove artist from album"
  test "autocomplete shows search results"
  test "autocomplete handles no results"
  test "duplicate prevention shows error"
  test "modal pre-populates parent resource"

  # Total: 8 tests
end
```

**Target Coverage**: >95% for controller and components, 100% for critical paths (create, update, destroy)

## Technical Approach - Additional Details

### 1. autoComplete.js Integration Pattern

**Installation via Importmap**:
```ruby
# config/importmap.rb
pin "@tarekraafat/autocomplete.js", to: "https://cdn.jsdelivr.net/npm/@tarekraafat/autocomplete.js@10.2.9/dist/autoComplete.min.js"
```

**CSS Loading (Optional - Library is unstyled)**:
Since we're using custom DaisyUI styling, we don't need the default CSS. All styling is done via the `resultsList` and `resultItem` configuration.

**Configuration Highlights**:
- `threshold: 2` - Minimum 2 characters before search
- `debounce: 300` - Wait 300ms after typing stops
- `cache: false` - Don't cache results (data changes frequently)
- `maxResults: 10` - Limit to 10 results
- `highlight: true` - Highlight matching text
- DaisyUI classes for dropdown styling

### 2. N+1 Query Prevention Strategy

**Current Issue**: Album/artist show pages will N+1 query album_artists

**Solution**: Enhanced eager loading in show actions:

```ruby
# Artists Controller
album_artists: { album: [:primary_image] }

# Albums Controller
album_artists: [:artist]
```

**Verification**: Use Bullet gem in development to catch N+1 queries:
```ruby
# Gemfile (development group)
gem 'bullet'
```

### 3. Position Management Logic

**Default Position Calculation**:
```ruby
# For adding artist to album
@album.album_artists.maximum(:position).to_i + 1

# For adding album to artist
1  # Default to primary artist position
```

**Why Different Defaults**:
- Album context: Append to end (most common use case)
- Artist context: Default to 1 (usually adding their own album)

**Reordering Strategy**:
- User clicks Edit button to open modal
- Modal shows current position in editable field
- User updates position and clicks Save
- Controller updates position
- Turbo Stream refreshes list (shows new order)
- Modal closes automatically after successful save
- No automatic gap-filling (positions can have gaps: 1, 2, 5, 7)

### 4. Turbo Stream Response Pattern

**Controller Response**:
```ruby
respond_to do |format|
  format.turbo_stream do
    render turbo_stream: [
      turbo_stream.replace("flash", ...),
      turbo_stream.replace(turbo_frame_id, ...)
    ]
  end
end
```

**Why Array of Streams**:
- Update multiple targets atomically
- Flash message + list refresh in one response
- Better UX than sequential updates

### 5. Error Handling Strategy

**Client-Side (Stimulus)**:
- AbortController cancels in-flight requests
- Empty results show "No results" message
- Network errors log to console, return empty array
- Prevents autocomplete from breaking on API failures

**Server-Side (Controller)**:
- Model validations prevent duplicates
- Flash error messages via Turbo Stream
- Graceful degradation with HTML format fallback

### 6. Accessibility Considerations

**Autocomplete Accessibility** (via autoComplete.js):
- `aria-autocomplete="both"`
- `aria-controls` links input to results
- `aria-expanded` indicates results visibility
- `aria-activedescendant` tracks keyboard navigation
- `role="listbox"` on results list
- `role="option"` on result items

**Keyboard Navigation**:
- Arrow Up/Down: Navigate results
- Enter: Select highlighted result
- Escape: Close results
- Tab: Navigate away (closes results)

**Screen Reader Support**:
- Announces result count
- Announces selected option
- Announces "No results" message

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Phase 3 Implementation Steps

1. **Verify autoComplete.js Installation** ✅
   - Already installed via yarn in package.json
   - Verify import works: `import autoComplete from "@tarekraafat/autocomplete.js"`

2. **Generate Controllers & Tests** ⬜
   ```bash
   cd web-app
   bin/rails generate controller Admin::Music::AlbumArtists create update destroy
   bin/rails generate stimulus autocomplete
   bin/rails generate component Autocomplete --sidecar
   ```

3. **Build Autocomplete System** ⬜
   - Create AutocompleteComponent with template
   - Implement autocomplete Stimulus controller
   - Test with existing artist/album search endpoints
   - Style with DaisyUI classes

4. **Implement AlbumArtistsController** ⬜
   - Create/update/destroy actions
   - Context detection logic
   - Turbo Stream responses
   - Error handling

5. **Update Album Show Page** ⬜
   - Add artists section with turbo frame
   - Create add artist modal with autocomplete
   - Create artists_list partial with edit modals
   - Test autocomplete integration

6. **Update Artist Show Page** ⬜
   - Add albums section with turbo frame
   - Create add album modal with autocomplete
   - Create albums_list partial with edit modals
   - Test autocomplete integration

7. **Update Routes** ⬜
   - Add nested album_artists resources
   - Use shallow option for update/destroy
   - Test route helpers

8. **Testing & Refinement** ⬜
   - Write controller tests (target: 13 tests)
   - Write component tests (target: 6 tests)
   - Write Stimulus controller tests (target: 7 tests)
   - Manual testing of all flows
   - Check for N+1 queries with Bullet
   - Mobile responsiveness verification
   - Accessibility testing with screen reader

### Approach Taken
*[To be filled during implementation]*

### Key Files Created
*[To be filled during implementation]*

### Key Files Modified
*[To be filled during implementation]*

### Challenges Encountered
*[To be filled during implementation]*

### Deviations from Plan
*[To be filled during implementation]*

### Testing Approach
*[To be filled during implementation]*

### Performance Considerations
*[To be filled during implementation]*

### Known Issues to Fix
*[To be filled during implementation]*

### Future Improvements
- [ ] Drag-and-drop position reordering (Sortable.js)
- [ ] Bulk add multiple artists/albums at once
- [ ] Position gap normalization (1, 2, 3 instead of 1, 5, 7)
- [ ] Keyboard shortcuts (Cmd+K to open add modal)
- [ ] Recent selections in autocomplete
- [ ] Image thumbnails in autocomplete results
- [ ] Optimistic UI updates (instant feedback before server response)

### Lessons Learned
*[To be filled during implementation]*

### Related PRs
*[To be created when ready to merge]*

### Documentation Updated
- [ ] Class documentation for Admin::Music::AlbumArtistsController
- [ ] Component documentation for AutocompleteComponent (global, not admin-specific)
- [ ] Stimulus controller documentation for autocomplete (global, not admin-specific)
- [ ] Updated artist show page documentation
- [ ] Updated album show page documentation
- [ ] This todo file with comprehensive implementation notes

### Tests Created
- [ ] Admin::Music::AlbumArtistsController tests (~13 tests)
- [ ] AutocompleteComponent tests (~6 tests)
- [ ] Stimulus controller tests for autocomplete (~7 tests)
- [ ] System tests for album_artists management (~8 tests)
- **Target Total**: ~34 tests, >95% coverage

## Next Phases

### Phase 4: Music Songs, Tracks, Categories (TODO #075)
- Admin::Music::SongsController
- Admin::Music::TracksController
- Admin::Music::CategoriesController
- Admin::Music::ReleasesController (enhanced from Phase 2)
- Use autocomplete component for album/release associations
- Apply album_artist patterns to song_artists join table

### Phase 5: Music Credits & More Join Tables (TODO #076)
- Admin::Music::CreditsController (polymorphic join table)
- Admin::Music::SongArtistsController (same pattern as album_artists)
- Reuse autocomplete component extensively
- Apply position management patterns

### Phase 6: Music Rankings Admin (TODO #077)
- Admin::Music::ArtistsRankingConfigurationsController
- Admin::Music::AlbumsRankingConfigurationsController
- Admin::Music::SongsRankingConfigurationsController

### Phase 7: Global Resources (TODO #078)
- Admin::PenaltiesController
- Admin::UsersController

### Phase 8: Movies, Books, Games (TODO #079-081)
- Replicate Music patterns for other domains

### Phase 9: Avo Removal (TODO #082)
- Remove Avo gem
- Clean up Avo routes/initializers
- Remove all Avo resource/action files
- Update documentation

## Research References

### autoComplete.js Documentation
- [Official Website](https://tarekraafat.github.io/autoComplete.js/) - Interactive demos and docs
- [GitHub Repository](https://github.com/TarekRaafat/autoComplete.js) - Source code and issues
- [NPM Package](https://www.npmjs.com/package/@tarekraafat/autocomplete.js) - Package info
- Latest Version: v10.2.9 (stable)
- License: Apache 2.0
- Size: 1.5kB - 9kB depending on config
- WAI-ARIA 1.2 Compliant

### Stimulus & Hotwire Patterns
- [Stimulus Controllers](https://stimulus.hotwired.dev/) - Official docs
- [Turbo Streams](https://turbo.hotwired.dev/handbook/streams) - Multi-target updates
- [Hotwire Discussion: Autocomplete](https://discuss.hotwired.dev/t/search-autocomplete-with-stimulus-and-rails/519)

### DaisyUI Components Used
- Modal: Native `<dialog>` with `.modal` class
- Form Controls: `.form-control`, `.input`, `.label`
- Dropdown: `.dropdown-content`, `.menu` for results list
- Tables: `.table`, `.table-zebra` for lists
- Badges: `.badge` for counts

### Rails Patterns
- Nested Resources with Shallow Routes
- Turbo Frame partial updates
- ViewComponent reusability
- Strong Parameters
- Eager Loading strategies

## Additional Resources
- [Phase 1 Spec](todos/072-custom-admin-phase-1-artists.md) - Artists implementation
- [Phase 2 Spec](todos/073-custom-admin-phase-2-albums.md) - Albums implementation
- [Music::AlbumArtist Model Docs](models/music/album_artist.md) - Model documentation
- [DaisyUI Modal Component](https://daisyui.com/components/modal/) - Modal patterns
- [autoComplete.js Guide](https://www.cssscript.com/fast-autocomplete-typeahead/) - Comprehensive tutorial
