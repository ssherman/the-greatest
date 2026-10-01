# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class ApplyAuthorFactsTest < ActiveSupport::TestCase
        DESCRIPTION = ("Her poems and essays followed Paris between the wars, and she edited a small review that printed young writers. " * 3).strip

        def setup
          @author = ::Books::Author.create!(name: "Anna Brenner")
        end

        def facts(overrides = {})
          {
            recognized: true, confidence: "high",
            birth_year: {value: 1901, confidence: "high"},
            death_year: {value: 1980, confidence: "high"},
            gender: {value: "female", confidence: "high"},
            nationalities: {value: ["French"], confidence: "high"},
            description: {value: DESCRIPTION, confidence: "high"}
          }.deep_merge(overrides)
        end

        def apply(reviewed: {text: DESCRIPTION, review: nil, reason: nil}, citations: [], **overrides)
          ApplyAuthorFacts.call(author: @author, facts: facts(overrides), citations: citations, description: reviewed)
        end

        # A fresh author per call, so each value is judged on its own.
        def reason_for(name, value)
          @author = ::Books::Author.create!(name: "Anna Brenner")
          apply(name => {value: value}).data[:facts][ApplyAuthorFacts::LEDGER_NAMES.fetch(name)]["reason"]
        end

        test "fills every blank and records each fact with its confidence" do
          result = apply

          @author.reload
          assert_equal [1901, 1980, "female", ["French"]], [@author.birth_year, @author.death_year, @author.gender, @author.countries.map(&:name)]
          assert_equal [DESCRIPTION, "ai_generated"], [@author.descriptions.sole.content, @author.descriptions.sole.source]
          assert_equal({"value" => 1901, "applied" => true, "reason" => "filled", "confidence" => "high"}, result.data[:facts]["birth_year"])
          assert_equal %w[birth_year death_year gender countries description], result.data[:applied]
        end

        test "a stored value is never overwritten, and a different one is a conflict" do
          @author.update!(birth_year: 1900, gender: :male)

          result = apply

          @author.reload
          assert_equal [1900, "male", "Anna Brenner"], [@author.birth_year, @author.gender, @author.name]
          assert_equal ["conflict", 1900], result.data[:facts]["birth_year"].values_at("reason", "stored")
          assert_equal "conflict", result.data[:facts]["gender"]["reason"]
        end

        test "an unspecified gender counts as blank" do
          @author.update!(gender: :unspecified)

          apply

          assert_equal "female", @author.reload.gender
        end

        test "a fact the model gave low confidence is recorded, not applied" do
          result = apply(birth_year: {confidence: "low"}, description: {confidence: "low"})

          @author.reload
          assert_nil @author.birth_year
          assert_equal 1980, @author.death_year
          assert_equal ["low_confidence", "low"], result.data[:facts]["birth_year"].values_at("reason", "confidence")
          assert_equal ["low_confidence", false], result.data[:facts]["description"].values_at("reason", "applied")
          assert_equal 0, @author.descriptions.count
        end

        test "years are Common Era, no later than this year, and a death is no earlier than the birth" do
          reasons = [
            reason_for(:birth_year, Date.current.year + 1), reason_for(:birth_year, 0), reason_for(:birth_year, -50),
            reason_for(:birth_year, "1901"), reason_for(:death_year, 1850)
          ]

          assert_equal %w[invalid invalid invalid invalid invalid], reasons
        end

        test "gender is male, female or non_binary, in any spelling; anything else is invalid" do
          assert_equal "invalid", reason_for(:gender, "other")

          reason_for(:gender, "Non-binary")

          assert_equal "non_binary", @author.reload.gender
        end

        test "nationalities fill countries only when the author has none, and an unknown one is recorded" do
          first = apply(nationalities: {value: ["French", "Martian"]})

          assert_equal [["French"], ["Martian"]], [@author.reload.countries.map(&:name), first.data[:facts]["countries"]["unmatched"]]

          again = apply(nationalities: {value: ["Japanese"]})

          assert_equal ["already_set", ["French"]], [again.data[:facts]["countries"]["reason"], @author.reload.countries.map(&:name)]
        end

        test "no nationalities record null" do
          assert_equal "null", apply(nationalities: {value: []}).data[:facts]["countries"]["reason"]
        end

        test "the runner's verdict on the description is recorded, and nothing is written" do
          result = apply(reviewed: {text: DESCRIPTION, review: {"style_violations" => ["semicolon"]}, reason: "rejected"})

          entry = result.data[:facts]["description"]
          assert_equal ["rejected", false, {"style_violations" => ["semicolon"]}], entry.values_at("reason", "applied", "review")
          assert_equal 0, @author.reload.descriptions.count
        end

        test "an existing AI description is kept" do
          @author.assign_description(source: :ai_generated, content: "An earlier AI description.")
          @author.save!

          result = apply

          assert_equal "already_set", result.data[:facts]["description"]["reason"]
          assert_equal "An earlier AI description.", @author.reload.descriptions.sole.content
        end

        test "a written description cites the first research citation" do
          apply(citations: ["https://example.org/a", "https://example.org/b"])

          assert_equal "https://example.org/a", @author.reload.descriptions.sole.source_url
        end

        test "no description from the runner records null" do
          assert_equal "null", apply(reviewed: nil).data[:facts]["description"]["reason"]
        end
      end
    end
  end
end
