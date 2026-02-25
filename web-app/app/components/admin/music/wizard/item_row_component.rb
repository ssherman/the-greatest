# frozen_string_literal: true

# Music-specific base component for wizard review step item rows.
# Provides default source_badge with MusicBrainz support.
# Songs and Albums subclasses inherit from this.
#
class Admin::Music::Wizard::ItemRowComponent < Wizard::ItemRowComponent
  private

  def source_badge
    if item.metadata["opensearch_match"]
      score = item.metadata["opensearch_score"]
      score_text = score ? " #{score.to_f.round(1)}" : ""
      {text: "OS#{score_text}", css_class: "badge badge-success badge-sm", title: "OpenSearch Match"}
    elsif item.metadata["musicbrainz_match"]
      {text: "MB", css_class: "badge badge-info badge-sm", title: "MusicBrainz Match"}
    elsif supports_manual_link? && item.metadata["manual_link"]
      {text: "Manual", css_class: "badge badge-primary badge-sm", title: "Manual Link"}
    else
      {text: "-", css_class: "badge badge-ghost badge-sm", title: "No Match"}
    end
  end
end
