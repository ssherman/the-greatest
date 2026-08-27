# frozen_string_literal: true

class Admin::Lists::ShowComponent < ViewComponent::Base
  include Admin::ListsHelper

  def initialize(list:, domain_config:)
    @list = list
    @domain_config = domain_config
  end

  private

  attr_reader :list, :domain_config

  def show_musicbrainz_field?
    domain_config[:extra_show_fields].include?(:musicbrainz_series_id)
  end

  def research_prompt_supported?
    Admin::Lists::ResearchPromptModalComponent::DOMAIN_CONFIG.key?(list.type)
  end

  # An auto-generated list belongs to the generator: it rewrites the items
  # nightly, the model refuses hand edits, and deleting the list would take its
  # public URL, its RankedList row and its penalties with it. Hide every write
  # affordance rather than invite a click that will only be refused.
  def items_editable?
    helpers.current_user_can_write? && !list.auto_generated?
  end

  def metadata_card_visible?
    list.number_of_voters.present? ||
      list.estimated_quality.present? ||
      list.num_years_covered.present? ||
      (show_musicbrainz_field? && list.musicbrainz_series_id.present?)
  end
end
