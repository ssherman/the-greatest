# frozen_string_literal: true

class Admin::Music::Songs::Wizard::SourceStepComponent < ViewComponent::Base
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
end
