# frozen_string_literal: true

# ListWizardController handles the multi-step wizard for importing games into a list.
# Includes shared wizard functionality from BaseListWizardController concern.
#
# Games wizard only supports custom_html import source.
# Uses IGDB for enrichment instead of MusicBrainz.
#
class Admin::Games::ListWizardController < Admin::Games::BaseController
  include BaseListWizardController

  protected

  # Games only supports custom_html import (no series import)
  def valid_import_sources
    %w[custom_html]
  end

  private

  def list_class
    Games::List
  end

  def entity_id_key
    "game_id"
  end

  def enrichment_id_key
    "igdb_id"
  end

  # Configuration for job-based wizard steps
  def job_step_config
    @job_step_config ||= {
      "parse" => {
        job_class: "Games::WizardParseListJob",
        action_name: "Parsing",
        re_run_param: nil
      },
      "enrich" => {
        job_class: "Games::WizardEnrichListItemsJob",
        action_name: "Enrichment",
        re_run_param: :reenrich
      },
      "validate" => {
        job_class: "Games::WizardValidateListItemsJob",
        action_name: "Validation",
        re_run_param: :revalidate
      },
      "import" => {
        job_class: "Games::WizardImportGamesJob",
        action_name: "Import",
        re_run_param: nil,
        set_completed_on_advance: true
      }
    }.freeze
  end

  def load_review_step_data
    @items = @list.list_items.ordered.includes(listable: {game_companies: :company})
    @total_count = @items.count
    @valid_count = @items.count(&:verified?)
    @invalid_count = @items.count { |i| i.metadata["ai_match_invalid"] }
    @missing_count = @total_count - @valid_count - @invalid_count
  end

  def load_import_step_data
    @all_items = @list.list_items.ordered
    @linked_items = @all_items.where.not(listable_id: nil)
    @items_to_import = @all_items.where(listable_id: nil)
      .where("metadata->>'igdb_id' IS NOT NULL")
    @items_without_match = @all_items.where(listable_id: nil)
      .where("metadata->>'igdb_id' IS NULL")
  end
end
