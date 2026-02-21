# frozen_string_literal: true

module Admin::Games::ListItemsActionsHelper
  def item_label(item)
    title = item.metadata["title"].presence || "Unknown Title"
    developers = Array(item.metadata["developers"]).join(", ").presence || "Unknown Developer"
    "##{item.position} - \"#{title}\" by #{developers}"
  end

  def formatted_metadata(item)
    JSON.pretty_generate(item.metadata || {})
  end
end
