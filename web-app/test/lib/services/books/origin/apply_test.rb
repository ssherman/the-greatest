# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Origin
      class ApplyTest < ActiveSupport::TestCase
        setup do
          @book = ::Books::Book.create!(title: "Apply Test Book", first_published_year: 1900,
            original_language: Language.first)
          @unknown = ::Books::Country.find_or_create_by!(name: "Unknown")
          @french = ::Books::Country.find_or_create_by!(name: "French")
          @american = ::Books::Country.find_or_create_by!(name: "American")
          ::Books::Country.find_or_create_by!(name: "British")
          @book.countries << @unknown
        end

        def hold(country)
          @book.book_countries.destroy_all
          @book.countries << country
        end

        def dossier(wikidata: true, country_matches: [], infobox_country: nil)
          facts = {"schema_version" => 2}
          facts["wikidata"] = {"qid" => "Q1", "country_matches" => country_matches} if wikidata
          facts["wikipedia"] = {"title" => "T", "infobox" => {"country" => infobox_country}} if infobox_country
          @book.enrichments.create!(kind: "books.evidence", outcome: :applied, facts: facts)
          Categorize::Dossier.build(book: @book.reload)
        end

        def apply(dossier, nationality, confidence)
          Apply.call(book: @book, dossier: dossier, nationality: nationality, confidence: confidence)
        end

        test "a high answer replaces the Unknown placeholder" do
          before = @unknown.reload.book_count
          result = apply(dossier, "French", "high")
          assert_equal [true, "filled", "French", ["Unknown"]],
            [result.data[:applied], result.data[:reason], result.data[:country], result.data[:replaced]]
          assert_equal ["French"], @book.reload.countries.map(&:name)
          assert_equal before - 1, @unknown.reload.book_count
          assert SearchIndexRequest.exists?(parent: @book, action: :index_item)
        end

        test "a medium answer needs Wikidata or the infobox" do
          assert_equal "unsupported", apply(dossier(wikidata: false), "French", "medium").data[:reason]
          assert_equal "filled", apply(dossier(infobox_country: "France"), "French", "medium").data[:reason]
        end

        test "a medium answer is supported by Wikidata matches" do
          assert_equal "filled", apply(dossier(country_matches: ["French"]), "French", "medium").data[:reason]
        end

        test "low confidence writes nothing" do
          result = apply(dossier, "French", "low")
          assert_equal ["low_confidence", false, "French"], [result.data[:reason], result.data[:applied], result.data[:country]]
          assert_empty @book.reload.countries.reject { it.name == "Unknown" }
        end

        test "confidence is compared lowercase and the nationality is stripped" do
          assert_equal "filled", apply(dossier, "  French ", "High").data[:reason]
        end

        test "a real country is never overwritten, and an unsupported difference is not a disagreement" do
          hold(@american)
          result = apply(dossier(wikidata: false), "British", "high")
          assert_equal ["already_set", ["American"], ["American"]],
            [result.data[:reason], @book.reload.countries.map(&:name), result.data[:held]]
        end

        test "the held country matching the answer is already_set" do
          hold(@american)
          result = apply(dossier(country_matches: ["American"]), "American", "high")
          assert_equal ["already_set", false], [result.data[:reason], result.data[:applied]]
        end

        test "a high difference that Wikidata backs is a disagreement and still writes nothing" do
          hold(@american)
          result = apply(dossier(country_matches: ["British"]), "British", "high")
          assert_equal ["disagreement", ["American"], "British", false],
            [result.data[:reason], result.data[:held], result.data[:country], result.data[:applied]]
          assert_equal ["American"], @book.reload.countries.map(&:name)
        end

        test "a real country that lands after the dossier was built is not overwritten" do
          stale = dossier
          @book.countries << ::Books::Country.find_or_create_by!(name: "Irish")
          result = apply(stale, "French", "high")
          assert_equal ["already_set", false, ["Irish"]], [result.data[:reason], result.data[:applied], result.data[:held]]
          assert_equal ["Irish", "Unknown"], @book.reload.countries.map(&:name).sort
        end

        test "a blank answer is null" do
          result = apply(dossier, " ", "high")
          assert_equal ["null", false], [result.data[:reason], result.data[:applied]]
          assert_equal "null", apply(dossier, nil, "high").data[:reason]
        end

        test "Unknown, Multiple and multiple are placeholder answers" do
          %w[Unknown Multiple multiple].each do |n|
            result = apply(dossier, n, "high")
            assert_equal ["placeholder_answer", nil], [result.data[:reason], result.data[:country]]
          end
        end

        test "a mixed nationality is no_match with the raw answer" do
          result = apply(dossier, "Chinese American", "high")
          assert_equal ["no_match", "Chinese American", nil], [result.data[:reason], result.data[:raw], result.data[:country]]
        end

        test "a country name answer resolves" do
          assert_equal "French", apply(dossier, "France", "high").data[:country]
        end
      end
    end
  end
end
