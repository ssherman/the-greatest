# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class CleanLegacyWikipediaTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Michael Harriot")
          @entity = ::Wikidata::Entity.from_payload(::Wikidata::Distiller.call(wikidata_entity("Q100", label: "Michael Harriot", enwiki: "Michael Harriot")))
        end

        def legacy(url)
          @author.descriptions.create!(source: :wikipedia, content: "Legacy text.", source_url: url)
        end

        def lead(title, item, page_id: 1)
          ::Wikipedia::Lead.new(language: "en", page_id: page_id, title: title, url: "https://en.wikipedia.org/wiki/#{title.tr(" ", "_")}",
            extract: "", wikibase_item: item, disambiguation: false, raw: "{}")
        end

        def clean(entity, client = FakeWikipediaClient.new) = CleanLegacyWikipedia.call(author: @author, entity: entity, client: client)

        test "keeps a description whose URL is the matched item's sitelink, without calling Wikipedia" do
          row = legacy("https://en.wikipedia.org/wiki/Michael_Harriot")
          client = FakeWikipediaClient.new

          fact = clean(@entity, client)

          assert_equal ["kept", "sitelink"], fact["value"].first.values_at("verdict", "why")
          assert row.reload.normal?
          assert_empty client.calls
        end

        test "deprecates a description whose page is another item (the TV chef)" do
          row = legacy("https://en.wikipedia.org/wiki/Ainsley_Harriott")

          fact = clean(@entity, FakeWikipediaClient.new({["en", "Ainsley Harriott"] => lead("Ainsley Harriott", "Q4697012")}))

          assert row.reload.deprecated?
          assert_equal ["deprecated", "different_item", "Q4697012"], fact["value"].first.values_at("verdict", "why", "page_item")
          assert_equal ["deprecated", true], fact.values_at("reason", "applied")
        end

        test "keeps a description on a redirect title that resolves to the matched item" do
          row = legacy("https://en.wikipedia.org/wiki/M._Harriot")

          clean(@entity, FakeWikipediaClient.new({["en", "M. Harriot"] => lead("Michael Harriot", "Q100")}))

          assert row.reload.normal?
        end

        test "deprecates every Wikipedia description of an author who could not be matched" do
          row = legacy("https://en.wikipedia.org/wiki/Michael_Harriot")

          fact = clean(nil)

          assert row.reload.deprecated?
          assert_equal "author_unmatched", fact["value"].first["why"]
        end

        test "decodes percent-encoded titles and reads mobile URLs" do
          author = ::Books::Author.create!(name: "Arnaldur Indriðason")
          entity = ::Wikidata::Entity.from_payload(::Wikidata::Distiller.call(wikidata_entity("Q300", label: "Arnaldur Indriðason", enwiki: "Arnaldur Indriðason")))
          row = author.descriptions.create!(source: :wikipedia, content: "x", source_url: "https://en.m.wikipedia.org/wiki/Arnaldur_Indri%C3%B0ason")

          CleanLegacyWikipedia.call(author: author, entity: entity, client: FakeWikipediaClient.new)

          assert row.reload.normal?
        end

        test "deprecates a description whose URL is not a Wikipedia article" do
          row = legacy("https://example.com/somewhere")

          assert_equal "unreadable_url", clean(@entity)["value"].first["why"]
          assert row.reload.deprecated?
        end

        test "returns nil, touching nothing, when the author has no active Wikipedia description" do
          ai = @author.descriptions.create!(source: :ai_generated, content: "AI text.")
          @author.descriptions.create!(source: :wikipedia, content: "Old.", source_url: "https://en.wikipedia.org/wiki/X", rank: :deprecated)

          assert_nil clean(nil)
          assert ai.reload.normal?
        end
      end
    end
  end
end
