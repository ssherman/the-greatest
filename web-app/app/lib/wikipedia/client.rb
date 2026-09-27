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
      raise ArgumentError, "Invalid Wikipedia language #{language.inspect}" unless language.to_s.match?(LANGUAGE)
      raise ArgumentError, "Title cannot be blank" if title.to_s.strip.empty?

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
  end
end
