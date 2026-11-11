# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Categories
      class AddAliasesTest < ActiveSupport::TestCase
        setup do
          @book = ::Books::Book.create!(title: "Alias Test Book", first_published_year: 1900, original_language: languages(:english))
          @war = ::Books::Category.create!(name: "Alias War Fiction", category_type: "genre")
          @satire = ::Books::Category.create!(name: "Alias Satire", category_type: "genre", alternative_names: ["lampoon"])
        end

        def judged(*entries, book: @book)
          facts = {"label" => "alias-run", "path" => "judge", "context" => "backfill", "answer" => {"unlisted_genres" => entries},
                   "mapping" => {"resolved" => [], "unmatched" => []},
                   "apply" => {"added" => [], "confirmed" => [], "removed" => [], "held_back" => [], "type" => {}}}
          book.enrichments.create!(kind: "books.categories", mode: :knowledge, outcome: :applied, facts: facts)
        end

        def entry(name, genre) = {"name" => name, "closest_id" => genre&.id}

        def perform(apply: false, **opts) = AddAliases.call(label: "alias-run", apply: apply, **opts)

        test "a dry run reports what it would add and writes nothing" do
          judged(entry("war novel", @war))
          data = perform.data
          assert_equal [{name: "war novel", genre: "Alias War Fiction"}], data[:added]
          assert_empty data[:skipped]
          assert_empty @war.reload.alternative_names
        end

        test "apply adds the name to the genre's alternative names" do
          judged(entry("war novel", @war), entry("satirical novel", @satire))
          perform(apply: true)
          assert_equal ["war novel"], @war.reload.alternative_names
          assert_equal ["lampoon", "satirical novel"], @satire.reload.alternative_names
        end

        test "NAMES limits the run to those names and MIN to a minimum count" do
          judged(entry("war novel", @war), entry("satirical novel", @satire))
          other = ::Books::Book.create!(title: "Alias Other Book", first_published_year: 1900, original_language: languages(:english))
          judged(entry("war novel", @war), book: other)
          assert_equal ["war novel"], perform(names: ["War Novel"]).data[:added].map { |a| a[:name] }
          assert_equal ["war novel"], perform(min_count: 2).data[:added].map { |a| a[:name] }
          assert_equal 2, perform.data[:added].size
        end

        test "a name that already matches an active genre is skipped and reported" do
          judged(entry("lampoon", @war), entry("alias satire", @war))
          data = perform(apply: true).data
          assert_empty data[:added]
          assert_equal [["alias satire", "already matches Alias Satire"], ["lampoon", "already matches Alias Satire"]],
            data[:skipped].map { |s| [s[:name], s[:reason]] }.sort
          assert_empty @war.reload.alternative_names
        end

        test "a name suggested for two genres is added once" do
          judged(entry("war novel", @war), entry("war novel", @satire))
          data = perform.data
          assert_equal 1, data[:added].size
          assert_equal ["already suggested for another genre in this run"], data[:skipped].map { |s| s[:reason] }
        end

        test "the most common original casing is written, never retitled" do
          other = ::Books::Book.create!(title: "Alias Other Book", first_published_year: 1900, original_language: languages(:english))
          third = ::Books::Book.create!(title: "Alias Third Book", first_published_year: 1900, original_language: languages(:english))
          judged(entry("War novel", @war))
          judged(entry("war Novel", @war), book: other)
          judged(entry("war Novel", @war), book: third)
          perform(apply: true)
          assert_equal ["war Novel"], @war.reload.alternative_names
        end

        test "a suggestion with no genre is ignored and no category is ever created" do
          judged(entry("odd name", nil))
          assert_no_difference -> { ::Books::Category.count } do
            data = perform(apply: true).data
            assert_empty data[:added]
            assert_empty data[:skipped]
          end
        end
      end
    end
  end
end
