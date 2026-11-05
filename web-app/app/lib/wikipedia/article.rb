# frozen_string_literal: true

module Wikipedia
  # One article split into the parts book evidence uses: the lead, the plot
  # section, and a few infobox fields. CC BY-SA text: evidence for the AI
  # step, never shown on the site.
  Article = Data.define(:title, :url, :page_id, :lead, :plot, :infobox)
end
