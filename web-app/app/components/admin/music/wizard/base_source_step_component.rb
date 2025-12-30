# frozen_string_literal: true

# Base component for wizard source step.
# Displays import source selection (Custom HTML vs MusicBrainz Series).
#
# Subclasses must implement:
#   - advance_step_path: Path helper for form submission
#   - entity_name: "song" or "album" for display text
#
class Admin::Music::Wizard::BaseSourceStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  def musicbrainz_available?
    list.musicbrainz_series_id.present?
  end

  def default_import_source
    return list.wizard_state["import_source"] if list.wizard_state&.[]("import_source").present?
    return "musicbrainz_series" if musicbrainz_available?
    nil
  end

  private

  attr_reader :list

  # Abstract methods - subclasses must implement
  def advance_step_path
    raise NotImplementedError, "Subclass must implement #advance_step_path"
  end

  def entity_name
    raise NotImplementedError, "Subclass must implement #entity_name"
  end
end
