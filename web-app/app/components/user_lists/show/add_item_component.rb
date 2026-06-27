# frozen_string_literal: true

# Inline typeahead search box on the list show page (/my/lists/:id) that lets the
# owner add an existing listable (album/song/game) to the list (02e).
#
# Renders only for listable types backed by a search index (see
# Search::ListableAutocomplete). Reuses AutocompleteComponent for the debounced
# typeahead; the paired user-list-add-item Stimulus controller posts the selection
# to the 02a items#create endpoint, then reloads the page.
#
# The show action is owner-only, so rendering this for every show-page viewer is
# correct today. If public list viewing lands (02d), gate on ownership.
class UserLists::Show::AddItemComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
    @listable_type = list.class.listable_class.name
  end

  # ViewComponent render predicate: skip entirely for non-searchable types.
  def render?
    Search::ListableAutocomplete.searchable?(listable_type)
  end

  def search_url
    helpers.listable_search_path(listable_type: listable_type)
  end

  def placeholder
    "Search for a #{item_noun} to add…"
  end

  private

  attr_reader :list, :listable_type

  # "Music::Album" => "album", "Games::Game" => "game" — derived from the class
  # name so the noun never drifts from Search::ListableAutocomplete::CONFIGS.
  def item_noun
    listable_type.demodulize.underscore.humanize.downcase
  end
end
