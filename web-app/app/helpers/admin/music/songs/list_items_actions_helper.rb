module Admin::Music::Songs::ListItemsActionsHelper
  # Helper methods for modal content partials

  def item_label(item)
    title = item.metadata["title"].presence || "Unknown Title"
    artists = Array(item.metadata["artists"]).join(", ").presence || "Unknown Artist"
    "##{item.position} - \"#{title}\" by #{artists}"
  end

  def formatted_metadata(item)
    JSON.pretty_generate(item.metadata || {})
  end

  def musicbrainz_available?(item)
    Array(item.metadata["mb_artist_ids"]).any?
  end
end
