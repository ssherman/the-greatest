# frozen_string_literal: true

require "test_helper"

module Wikipedia
  class LeadTest < ActiveSupport::TestCase
    def lead
      Lead.new(language: "en", page_id: 1, title: "Leo Tolstoy", url: "https://en.wikipedia.org/wiki/Leo_Tolstoy",
        extract: "Count Lev…", wikibase_item: "Q7243", disambiguation: false, raw: "{}")
    end

    test "round-trips through its payload, without the raw body" do
      payload = lead.to_payload
      copy = Lead.from_payload(payload)

      assert_not payload.key?("raw")
      assert_equal [lead.source_id, lead.url, lead.wikibase_item, false], [copy.source_id, copy.url, copy.wikibase_item, copy.disambiguation?]
      assert_nil copy.raw
    end
  end
end
