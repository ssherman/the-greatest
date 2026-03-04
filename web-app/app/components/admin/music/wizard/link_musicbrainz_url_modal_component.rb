# frozen_string_literal: true

class Admin::Music::Wizard::LinkMusicbrainzUrlModalComponent < ViewComponent::Base
  def initialize(list_item:, form_url:, entity_type:, shared_modal_class:)
    @list_item = list_item
    @form_url = form_url
    @entity_type = entity_type
    @shared_modal_class = shared_modal_class
  end

  private

  attr_reader :list_item, :form_url, :entity_type, :shared_modal_class

  def frame_id
    shared_modal_class::FRAME_ID
  end

  def dialog_id
    shared_modal_class::DIALOG_ID
  end

  def error_id
    shared_modal_class::ERROR_ID
  end

  def item_label
    title = list_item.metadata["title"].presence || "Unknown Title"
    artists = Array(list_item.metadata["artists"]).join(", ").presence || "Unknown Artist"
    "##{list_item.position} - \"#{title}\" by #{artists}"
  end

  def label_text
    case entity_type
    when :recording then "MusicBrainz URL or Recording ID:"
    when :release_group then "MusicBrainz URL or Release Group ID:"
    end
  end

  def placeholder
    case entity_type
    when :recording then "e.g., https://musicbrainz.org/recording/1d2be447-71b0-470a-ad38-925ecaf83c08"
    when :release_group then "e.g., https://musicbrainz.org/release-group/6258df90-78c7-3395-8830-e7b4328a002c"
    end
  end

  def submit_label
    case entity_type
    when :recording then "Link MusicBrainz Recording"
    when :release_group then "Link MusicBrainz Release"
    end
  end
end
