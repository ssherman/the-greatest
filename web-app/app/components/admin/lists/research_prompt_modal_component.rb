# frozen_string_literal: true

class Admin::Lists::ResearchPromptModalComponent < ViewComponent::Base
  DOMAIN_CONFIG = {
    "Games::List" => {
      noun_plural: "games",
      list_type_label: "Video Games",
      site_name: "The Greatest Games",
      creator_term: "creator or company"
    },
    "Music::Albums::List" => {
      noun_plural: "albums",
      list_type_label: "Albums",
      site_name: "The Greatest Albums",
      creator_term: "artist or group"
    },
    "Music::Songs::List" => {
      noun_plural: "songs",
      list_type_label: "Songs",
      site_name: "The Greatest Songs",
      creator_term: "artist or group"
    }
  }.freeze

  def initialize(list:)
    @list = list
  end

  def render?
    DOMAIN_CONFIG.key?(@list.type)
  end

  def research_prompt
    config = DOMAIN_CONFIG.fetch(@list.type)
    noun = config[:noun_plural]
    list_type = config[:list_type_label]
    site = config[:site_name]
    creator = config[:creator_term]

    title = @list.name
    url = @list.url.presence || "N/A"
    source = @list.source.presence || "N/A"
    year = @list.year_published.present? ? @list.year_published.to_s : "Unknown"

    <<~PROMPT
      I would like you to research the following #{list_type} List:

      title: #{title}
      url: #{url}
      source: #{source}
      Year Published: #{year}

      What I am looking for:

      1. **Number of Contributors (MOST IMPORTANT)**: How many people contributed to picking out the #{noun} on the list? This is critical for our ranking algorithm - lists with more contributors carry more weight. Be conservative in your estimate (err on the low side). If a range seems plausible, go with the lower-middle.

      2. **Contributor Details**:
         - Who contributed to picking out the #{noun} on the list?
         - Are the names of the people who contributed publicly listed?
         - Can the number of contributors be estimated? Do we know for sure there's more than one?

      3. **Confidence Level**: For each answer, indicate whether the information is:
         - Confirmed (explicitly stated by the source)
         - Estimated (reasonably inferred but not stated)
         - Unknown (cannot be determined)

      4. **Source Quality**: Is this source well-established and reputable? Is it a major publication, respected industry organization, or long-running institution?

      5. **List Characteristics**:
         - Is this a yearly/recurring award?
         - Is it limited to a specific genre or category of #{noun}?
         - Is it specific to a geographic region?
         - Is it focused on a specific #{creator}?

      6. **Summary/Description**: Write a 2-4 sentence description of this list for readers of my website #{site}. This description should summarize the criteria for the list, the purpose of the list, the methodology, and the credibility of the source.
    PROMPT
  end
end
