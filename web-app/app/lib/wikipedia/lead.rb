# frozen_string_literal: true

module Wikipedia
  # One article's plain-text lead, as Wikipedia::Client read it. The text is
  # CC BY-SA: evidence for the AI step, never shown on the site.
  class Lead
    SCHEMA_VERSION = 1
    FIELDS = %i[language page_id title url extract wikibase_item disambiguation].freeze

    attr_reader :language, :page_id, :title, :url, :extract, :wikibase_item, :raw

    def self.from_payload(payload)
      values = payload.to_h.stringify_keys
      new(**FIELDS.to_h { |field| [field, values[field.to_s]] })
    end

    def initialize(language:, page_id:, title:, url:, extract:, wikibase_item:, disambiguation:, raw: nil)
      @language = language
      @page_id = page_id
      @title = title
      @url = url
      @extract = extract
      @wikibase_item = wikibase_item
      @disambiguation = disambiguation == true
      @raw = raw
    end

    def disambiguation? = @disambiguation

    # Page ids survive renames, so a stored lead is keyed by one.
    def source_id = "#{language}:#{page_id}"

    def to_payload
      {
        "language" => language, "page_id" => page_id, "title" => title, "url" => url,
        "extract" => extract, "wikibase_item" => wikibase_item, "disambiguation" => disambiguation?
      }
    end
  end
end
