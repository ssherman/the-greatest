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

  def metadata_card_visible?
    list.number_of_voters.present? ||
      list.estimated_quality.present? ||
      list.num_years_covered.present? ||
      (show_musicbrainz_field? && list.musicbrainz_series_id.present?)
  end
end
