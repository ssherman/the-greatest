# frozen_string_literal: true

class Admin::Music::Albums::Wizard::ReviewStepComponent < ViewComponent::Base
  attr_reader :list, :items, :total_count, :valid_count, :invalid_count, :missing_count

  def initialize(list:, items: [], total_count: 0, valid_count: 0, invalid_count: 0, missing_count: 0)
    @list = list
    @items = items
    @total_count = total_count
    @valid_count = valid_count
    @invalid_count = invalid_count
    @missing_count = missing_count
  end

  def item_status(item)
    if item.verified?
      "valid"
    elsif item.metadata["ai_match_invalid"]
      "invalid"
    else
      "missing"
    end
  end

  def status_badge_class(status)
    case status
    when "valid"
      "badge badge-success badge-sm"
    when "invalid"
      "badge badge-error badge-sm"
    else
      "badge badge-ghost badge-sm"
    end
  end

  def status_badge_icon(status)
    case status
    when "valid"
      '<svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clip-rule="evenodd" /></svg>'.html_safe
    when "invalid"
      '<svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" /></svg>'.html_safe
    else
      '<svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M3 10a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1z" clip-rule="evenodd" /></svg>'.html_safe
    end
  end

  def row_background_class(status)
    case status
    when "invalid"
      "bg-error/10"
    when "missing"
      "bg-base-200"
    else
      ""
    end
  end

  def original_title(item)
    item.metadata["title"].presence || "Unknown Title"
  end

  def original_artists(item)
    Array(item.metadata["artists"]).join(", ").presence || "Unknown Artist"
  end

  def matched_title(item)
    if item.listable.present?
      item.listable.title
    elsif item.metadata["mb_release_group_name"].present?
      item.metadata["mb_release_group_name"]
    elsif item.metadata["album_name"].present?
      item.metadata["album_name"]
    end
  end

  def matched_artists(item)
    if item.listable.present? && item.listable.respond_to?(:artists)
      item.listable.artists.map(&:name).join(", ")
    elsif item.metadata["mb_artist_names"].present?
      Array(item.metadata["mb_artist_names"]).join(", ")
    elsif item.metadata["opensearch_artist_names"].present?
      Array(item.metadata["opensearch_artist_names"]).join(", ")
    end
  end

  def source_badge(item)
    if item.metadata["opensearch_match"]
      score = item.metadata["opensearch_score"]
      score_text = score ? " #{score.to_f.round(1)}" : ""
      {text: "OS#{score_text}", class: "badge badge-success badge-sm", title: "OpenSearch Match"}
    elsif item.metadata["musicbrainz_match"]
      {text: "MB", class: "badge badge-info badge-sm", title: "MusicBrainz Match"}
    elsif item.metadata["manual_link"]
      {text: "Manual", class: "badge badge-primary badge-sm", title: "Manual Link"}
    else
      {text: "-", class: "badge badge-ghost badge-sm", title: "No Match"}
    end
  end

  def percentage(count)
    return 0 if total_count.zero?
    ((count.to_f / total_count) * 100).round(1)
  end

  def verify_path(item)
    helpers.verify_admin_albums_list_item_path(list_id: list.id, id: item.id)
  end

  def modal_path(item, modal_type)
    helpers.modal_admin_albums_list_item_path(list_id: list.id, id: item.id, modal_type: modal_type)
  end

  def destroy_path(item)
    helpers.admin_albums_list_item_path(list_id: list.id, id: item.id)
  end
end
