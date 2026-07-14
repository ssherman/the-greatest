class Admin::Music::ListsController < Admin::ListsBaseController
  include Admin::DomainScopedAuth

  private

  def policy_class
    Music::ListPolicy
  end

  def item_label
    "Album"
  end

  def permitted_params
    super + [:musicbrainz_series_id]
  end

  def source_placeholder
    "e.g., Rolling Stone, NME, Pitchfork"
  end

  def country_placeholder
    "e.g., USA, Germany, UK"
  end

  def info_alert_text
    "#{item_label.pluralize} can be managed after creating the list using Items JSON import (future feature)"
  end

  def extra_form_fields
    [:musicbrainz_series_id]
  end

  def extra_show_fields
    [:musicbrainz_series_id]
  end
end
