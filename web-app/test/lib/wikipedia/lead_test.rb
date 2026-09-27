# frozen_string_literal: true

require "test_helper"

module Wikipedia
  class LeadTest < ActiveSupport::TestCase
    def lead(disambiguation: false)
      Lead.new(language: "en", page_id: 1, title: "Leo Tolstoy", url: "https://en.wikipedia.org/wiki/Leo_Tolstoy",
        extract: "Count Lev…", wikibase_item: "Q7243", disambiguation: disambiguation, raw: "{}")
    end

    test "serializes every field to a string-keyed payload, without the raw body" do
      payload = lead.to_payload

      assert_not payload.key?("raw")
      assert_equal({"language" => "en", "page_id" => 1, "title" => "Leo Tolstoy",
        "url" => "https://en.wikipedia.org/wiki/Leo_Tolstoy", "extract" => "Count Lev…",
        "wikibase_item" => "Q7243", "disambiguation" => false}, payload)
    end

    test "round-trips a false disambiguation through every reader" do
      copy = Lead.from_payload(lead(disambiguation: false).to_payload)

      assert_equal "en", copy.language
      assert_equal 1, copy.page_id
      assert_equal "Leo Tolstoy", copy.title
      assert_equal "https://en.wikipedia.org/wiki/Leo_Tolstoy", copy.url
      assert_equal "Count Lev…", copy.extract
      assert_equal "Q7243", copy.wikibase_item
      assert_not copy.disambiguation?
      assert_equal "en:1", copy.source_id
      assert_nil copy.raw
    end

    test "round-trips a true disambiguation through every reader" do
      copy = Lead.from_payload(lead(disambiguation: true).to_payload)

      assert_equal "en", copy.language
      assert_equal 1, copy.page_id
      assert_equal "Leo Tolstoy", copy.title
      assert_equal "https://en.wikipedia.org/wiki/Leo_Tolstoy", copy.url
      assert_equal "Count Lev…", copy.extract
      assert_equal "Q7243", copy.wikibase_item
      assert copy.disambiguation?
      assert_equal "en:1", copy.source_id
      assert_nil copy.raw
    end
  end
end
