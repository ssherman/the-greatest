# frozen_string_literal: true

# Music base class for list wizard controllers.
# Includes shared wizard functionality from BaseListWizardController concern.
#
# Provides music-specific defaults:
#   - valid_import_sources: ["custom_html", "musicbrainz_series"]
#   - source_step_next_index: Routes musicbrainz_series to review step
#   - load_review_step_data: Eager loads listable with artists
#   - load_import_step_data: Queries based on enrichment_id_key
#
# Subclasses must implement:
#   - list_class: Model class for list (e.g., Music::Songs::List)
#   - entity_id_key: Metadata key for entity ID (e.g., "song_id")
#   - enrichment_id_key: Metadata key for MusicBrainz ID (e.g., "mb_recording_id")
#   - job_step_config: Hash of step configurations with job classes
#
class Admin::Music::BaseListWizardController < Admin::Music::BaseController
  include BaseListWizardController

  protected

  def valid_import_sources
    %w[custom_html musicbrainz_series]
  end

  def source_step_next_index(import_source)
    (import_source == "musicbrainz_series") ? 5 : 1
  end

  private

  def load_review_step_data
    @items = @list.list_items.ordered.includes(listable: :artists)
    @total_count = @items.count
    @valid_count = @items.count(&:verified?)
    @invalid_count = @items.count { |i| i.metadata["ai_match_invalid"] }
    @missing_count = @total_count - @valid_count - @invalid_count
  end

  def load_import_step_data
    import_source = @list.wizard_state&.dig("import_source") || "custom_html"

    if import_source == "custom_html"
      @all_items = @list.list_items.ordered
      @linked_items = @all_items.where.not(listable_id: nil)
      @items_to_import = @all_items.where(listable_id: nil)
        .where("metadata->>'#{enrichment_id_key}' IS NOT NULL")
      @items_without_match = @all_items.where(listable_id: nil)
        .where("metadata->>'#{enrichment_id_key}' IS NULL")
    end
  end
end
