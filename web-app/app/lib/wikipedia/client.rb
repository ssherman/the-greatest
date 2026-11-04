# frozen_string_literal: true

module Wikipedia
  # Reads one article's lead by exact title, following redirects. There is
  # no search method, on purpose (spec §4): the legacy app searched
  # Wikipedia for "<name> Author" and attached the wrong page to one author
  # in six. An article is only ever reached as a Wikidata item's sitelink.
  class Client
    URL = "https://%s.wikipedia.org/w/api.php"
    LANGUAGE = /\A[a-z]{2,3}(-[a-z]+)*\z/

    def initialize(http: nil)
      @http = http || ::Wikimedia::Http.new
    end

    # nil when no page has this title.
    def lead(language:, title:)
      validate!(language, title)

      response = @http.action_api(format(URL, language),
        action: "query", prop: "extracts|pageprops|info", inprop: "url",
        exintro: 1, explaintext: 1, redirects: 1, titles: title)
      page = Array(response.data.dig("query", "pages")).first
      return nil if !page.is_a?(Hash) || page["missing"] || page["invalid"]

      pageprops = page["pageprops"].is_a?(Hash) ? page["pageprops"] : {}
      Lead.new(
        language: language.to_s, page_id: page["pageid"], title: page["title"], url: page["fullurl"],
        extract: page["extract"].to_s, wikibase_item: pageprops["wikibase_item"],
        disambiguation: pageprops.key?("disambiguation"), raw: response.body
      )
    end

    LEAD_BUDGET = 2_000
    PLOT_BUDGET = 6_000
    PLOT_HEADING = /\A(plot|plot summary|synopsis|summary|story|content|contents|overview)\z/i
    HEADING = /\A(={2,6})\s*(.+?)\s*\1\z/

    # The article's lead, plot section and infobox fields, or nil when the
    # page is missing, invalid or a disambiguation page. Two requests: the
    # plain-text extract, then section 0 as wikitext for the infobox.
    def article(language:, title:)
      validate!(language, title)

      response = @http.action_api(format(URL, language),
        action: "query", prop: "extracts|pageprops|info", inprop: "url",
        explaintext: 1, exsectionformat: "wiki", redirects: 1, titles: title)
      page = Array(response.data.dig("query", "pages")).first
      return nil if !page.is_a?(Hash) || page["missing"] || page["invalid"]
      return nil if page["pageprops"].is_a?(Hash) && page["pageprops"].key?("disambiguation")

      lead, plot = split_extract(page["extract"].to_s)
      Article.new(
        title: page["title"], url: page["fullurl"], page_id: page["pageid"],
        lead: lead, plot: plot, infobox: infobox_for(language, page["title"])
      )
    end

    private

    def validate!(language, title)
      raise ArgumentError, "Invalid Wikipedia language #{language.inspect}" unless language.to_s.match?(LANGUAGE)
      raise ArgumentError, "Title cannot be blank" if title.to_s.strip.empty?
    end

    def infobox_for(language, title)
      response = @http.action_api(format(URL, language),
        action: "parse", page: title, prop: "wikitext", section: 0, redirects: 1)
      Infobox.fields(response.data.dig("parse", "wikitext"))
    rescue ::Wikimedia::Exceptions::ApiError
      {}  # the lead and plot are still worth keeping
    end

    # Lead = text before the first heading; plot = the first matching
    # heading's text up to the next heading of the same or higher level.
    def split_extract(text)
      lead = []
      plot = nil
      plot_level = nil
      seen_heading = false
      text.each_line do |line|
        heading = line.strip.match(HEADING)
        if heading
          seen_heading = true
          level = heading[1].length
          break if plot_level && level <= plot_level

          if plot.nil? && heading[2].match?(PLOT_HEADING)
            plot = []
            plot_level = level
          end
        elsif plot_level
          plot << line
        elsif !seen_heading
          lead << line
        end
      end
      [lead.join.strip.first(LEAD_BUDGET).presence, plot&.join&.strip&.first(PLOT_BUDGET).presence]
    end
  end
end
