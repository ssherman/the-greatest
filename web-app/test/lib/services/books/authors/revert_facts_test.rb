# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class RevertFactsTest < ActiveSupport::TestCase
        URL = "https://en.wikipedia.org/wiki/Revert_Facts_Author"

        def setup
          @author = ::Books::Author.create!(name: "Revert Facts Author")
        end

        def revert(facts) = RevertFacts.call(author: @author, facts: facts)

        def filled(value, **extra) = {"value" => value, "applied" => true, "reason" => "filled"}.merge(extra.stringify_keys)

        def hold(type, value, author: @author) = author.identifiers.create!(identifier_type: type, value: value)

        test "removes the identifiers the run stamped and keeps those it found already set" do
          hold(:books_author_wikidata_qid, "Q1")
          hold(:books_author_isni, "0000000121")
          hold(:books_author_openlibrary_id, "OL1A")
          hold(:books_author_openlibrary_id, "OL2A")

          result = revert(
            "wikidata_qid" => filled("Q1"),
            "isni" => {"value" => "0000000121", "applied" => false, "reason" => "already_set"},
            "openlibrary_ids" => filled(["OL1A", "OL2A"], added: ["OL2A"])
          )

          assert_equal [["books_author_isni", "0000000121"], ["books_author_openlibrary_id", "OL1A"]],
            @author.identifiers.reload.pluck(:identifier_type, :value).sort
          assert_equal %w[wikidata_qid openlibrary_ids], result.data[:reverted]
        end

        test "another author holding the same value keeps it" do
          other = ::Books::Author.create!(name: "Other Author")
          hold(:books_author_viaf, "5391", author: other)
          hold(:books_author_viaf, "5391")

          revert("viaf" => filled("5391"))

          assert other.identifiers.exists?(identifier_type: "books_author_viaf", value: "5391")
          assert_not @author.identifiers.exists?(identifier_type: "books_author_viaf")
        end

        test "clears a year or gender the run wrote, and keeps one a person changed since" do
          @author.update!(birth_year: 1901, death_year: 1975, gender: :female)

          result = revert("birth_year" => filled(1901), "death_year" => filled(1980), "gender" => filled("female"))

          @author.reload
          assert_equal [nil, 1975, nil], [@author.birth_year, @author.death_year, @author.gender]
          assert_equal %w[birth_year gender], result.data[:reverted]
        end

        test "removes only the alternate names the run added" do
          @author.update!(alternate_names: ["Kept Name", "Added Name"])

          revert("alternate_names" => filled(["Added Name"]))

          assert_equal ["Kept Name"], @author.reload.alternate_names
        end

        test "removes the countries the run added, by id" do
          added = ::Books::Country.create!(name: "Revert Added")
          kept = ::Books::Country.create!(name: "Revert Kept")
          @author.author_countries.create!(country: added)
          @author.author_countries.create!(country: kept)

          # The fact's value is a stale name the country no longer has, so a
          # name-based removal would miss it: only the recorded country_ids
          # can find it.
          revert("countries" => filled(["Old Name"], country_ids: [added.id]))

          assert_equal [kept], @author.reload.countries.to_a
        end

        test "a ledger row from before country ids were recorded removes its countries by name" do
          added = ::Books::Country.create!(name: "Revert Named")
          other = ::Books::Country.create!(name: "Revert Other")
          @author.author_countries.create!(country: added)
          @author.author_countries.create!(country: other)

          revert("countries" => filled(["Revert Named"]))

          assert_equal [other], @author.reload.countries.to_a
        end

        test "removes the Wikipedia link the run added" do
          @author.external_links.create!(url: URL, name: "Wikipedia", source: :wikipedia, link_category: :information)
          other_url = "https://example.com/revert-facts-author"
          @author.external_links.create!(url: other_url, name: "Buy books", source: :amazon, link_category: :product_link)

          revert("wikipedia" => {"value" => URL, "applied" => true, "reason" => "linked", "page" => "en:9"})

          assert_equal [other_url], @author.reload.external_links.pluck(:url)
        end

        test "legacy Wikipedia descriptions the run deprecated return to normal rank" do
          row = @author.assign_description(source: :wikipedia, content: "A legacy lead.", source_url: URL)
          row.rank = :deprecated
          other = @author.assign_description(source: :ai_generated, content: "An AI description deprecated by a reject.")
          other.rank = :deprecated
          @author.save!

          revert("legacy_wikipedia" => {"value" => [{"description_id" => row.id, "verdict" => "deprecated", "why" => "different_item"}],
                                        "applied" => true, "reason" => "deprecated"})

          assert_equal "normal", row.reload.rank
          assert_equal "deprecated", other.reload.rank
        end

        test "facts not applied, and facts it does not know, are left alone" do
          @author.update!(birth_year: 1901)

          result = revert("birth_year" => {"value" => 1901, "applied" => false, "reason" => "conflict"},
            "description" => filled("Text"), "sources" => {"value" => [], "applied" => false, "reason" => "input"})

          assert_equal 1901, @author.reload.birth_year
          assert_equal [], result.data[:reverted]
        end
      end
    end
  end
end
