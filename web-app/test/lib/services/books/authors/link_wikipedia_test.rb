# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class LinkWikipediaTest < ActiveSupport::TestCase
        def setup
          @author = books_authors(:tolstoy)
          @entity = ::Wikidata::Entity.from_payload(::Wikidata::Distiller.call(wikidata_entity("Q7243", label: "Leo Tolstoy", enwiki: "Leo Tolstoy")))
        end

        def lead(item: "Q7243", disambiguation: false, raw: "{\"page\":1}")
          ::Wikipedia::Lead.new(language: "en", page_id: 18622119, title: "Leo Tolstoy", url: "https://en.wikipedia.org/wiki/Leo_Tolstoy",
            extract: "Count Lev Nikolayevich Tolstoy…", wikibase_item: item, disambiguation: disambiguation, raw: raw)
        end

        def link(client) = LinkWikipedia.call(author: @author, entity: @entity, client: client)

        test "links the article when the page names the same item back, and stores the lead" do
          result = link(FakeWikipediaClient.new({["en", "Leo Tolstoy"] => lead}))

          assert_equal ["https://en.wikipedia.org/wiki/Leo_Tolstoy", true, "linked"], result.data[:fact].values_at("value", "applied", "reason")
          link_row = @author.external_links.find_by!(url: "https://en.wikipedia.org/wiki/Leo_Tolstoy")
          assert_equal ["Wikipedia", "wikipedia", "information"], [link_row.name, link_row.source, link_row.link_category]
          assert_equal "en:18622119", result.data[:record].source_id
          assert_equal "Q7243", result.data[:record].payload["wikibase_item"]
        end

        test "ignores a page that reports a different item" do
          result = link(FakeWikipediaClient.new({["en", "Leo Tolstoy"] => lead(item: "Q999")}))

          assert_equal ["item_mismatch", "Q999"], result.data[:fact].values_at("reason", "page_item")
          assert_empty @author.external_links.where(source: :wikipedia)
          assert_equal 0, ::ExternalRecord.where(source: :wikipedia).count
        end

        test "ignores a disambiguation page" do
          result = link(FakeWikipediaClient.new({["en", "Leo Tolstoy"] => lead(disambiguation: true)}))

          assert_equal "disambiguation", result.data[:fact]["reason"]
          assert_empty @author.external_links.where(source: :wikipedia)
        end

        test "does nothing without an English sitelink, and never searches" do
          entity = ::Wikidata::Entity.from_payload(::Wikidata::Distiller.call(wikidata_entity("Q7243", label: "Leo Tolstoy")))
          client = FakeWikipediaClient.new

          result = LinkWikipedia.call(author: @author, entity: entity, client: client)

          assert_equal "no_sitelink", result.data[:fact]["reason"]
          assert_empty client.calls
        end

        test "a missing page is recorded" do
          assert_equal "missing", link(FakeWikipediaClient.new).data[:fact]["reason"]
        end

        test "a second run reads the stored lead and does not add a second link" do
          link(FakeWikipediaClient.new({["en", "Leo Tolstoy"] => lead}))
          client = FakeWikipediaClient.new

          result = link(client)

          assert_empty client.calls
          assert_equal "already_set", result.data[:fact]["reason"]
          assert_equal 1, @author.external_links.where(source: :wikipedia).count
        end
      end
    end
  end
end
