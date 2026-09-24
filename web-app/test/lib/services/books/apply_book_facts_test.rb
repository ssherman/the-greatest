require "test_helper"

module Services
  module Books
    class ApplyBookFactsTest < ActiveSupport::TestCase
      def setup
        @book = ::Books::Book.create!(title: "A Fresh Book")
      end

      def facts(overrides = {})
        {
          recognized: true,
          confidence: "high",
          first_published_year: {value: 1999, confidence: "high"},
          first_published_year_estimated: false,
          original_language: {value: "en", confidence: "high"},
          word_count: {value: 80_000, confidence: "medium"},
          page_range: {value: "300", confidence: "medium"},
          subtitle: {value: "A Subtitle", confidence: "high"},
          alternate_titles: {value: ["Fresh"], confidence: "medium"},
          origin_countries: {value: ["French"], confidence: "high"},
          book_type: {value: "fiction", confidence: "high"},
          series_name: {value: nil, confidence: "low"},
          series_number: {value: nil, confidence: "low"},
          description: {value: "A paragraph about a fresh book.", confidence: "high"}
        }.deep_merge(overrides)
      end

      def apply(overrides = {}, description: :default, citations: [], **fact_overrides)
        description = {text: "A paragraph about a fresh book.", review: {"spoilers" => false}, reason: nil} if description == :default
        ApplyBookFacts.call(book: @book, facts: facts(overrides.merge(fact_overrides)), citations: citations, description: description)
      end

      def human_clear!(field_name, new_value)
        correction = ::Correction.create!(correctable: @book, status: :resolved, notes: "Cleared #{field_name}.")
        correction.correction_fields.create!(field_name: field_name, status: :applied, new_value: new_value, applied_at: Time.current)
      end

      test "fills every blank scalar and records filled" do
        result = apply

        assert result.success?
        @book.reload
        assert_equal 1999, @book.first_published_year
        assert_equal languages(:english), @book.original_language
        assert_equal 80_000, @book.word_count
        assert_equal "300", @book.page_range
        assert_equal "A Subtitle", @book.subtitle
        %w[first_published_year original_language word_count page_range subtitle].each do |name|
          assert_equal "filled", result.data[:facts][name]["reason"], name
          assert result.data[:facts][name]["applied"], name
          assert_includes result.data[:applied], name
        end
      end

      test "never overwrites a value that is already set" do
        @book.update!(first_published_year: 1950, word_count: 10, page_range: "12", subtitle: "Kept", original_language: languages(:french))

        result = apply

        @book.reload
        assert_equal [1950, 10, "12", "Kept", languages(:french)],
          [@book.first_published_year, @book.word_count, @book.page_range, @book.subtitle, @book.original_language]
        %w[first_published_year original_language word_count page_range subtitle].each do |name|
          assert_equal "already_set", result.data[:facts][name]["reason"], name
          refute result.data[:facts][name]["applied"], name
        end
      end

      test "a human-cleared subtitle is never refilled" do
        human_clear!("subtitle", "")

        result = apply

        assert_nil @book.reload.subtitle
        assert_equal "human_cleared", result.data[:facts]["subtitle"]["reason"]
        refute result.data[:facts]["subtitle"]["applied"]
      end

      test "a null value is recorded as null and not applied" do
        result = apply(first_published_year: {value: nil, confidence: "low"})

        assert_nil @book.reload.first_published_year
        assert_equal "null", result.data[:facts]["first_published_year"]["reason"]
      end

      test "a whitespace-only subtitle is treated as null, not filled" do
        result = apply(subtitle: {value: "   ", confidence: "high"})

        assert_nil @book.reload.subtitle
        assert_equal "null", result.data[:facts]["subtitle"]["reason"]
        refute result.data[:facts]["subtitle"]["applied"]
      end

      test "carries each fact's confidence into the ledger" do
        result = apply

        assert_equal "medium", result.data[:facts]["word_count"]["confidence"]
        assert_equal "high", result.data[:facts]["first_published_year"]["confidence"]
      end

      test "original language matches by name when the value is not a code" do
        apply(original_language: {value: "english", confidence: "high"})

        assert_equal languages(:english), @book.reload.original_language
      end

      test "original language with no match is recorded as no_match and not applied" do
        result = apply(original_language: {value: "Englisch", confidence: "high"})

        assert_nil @book.reload.original_language
        assert_equal "no_match", result.data[:facts]["original_language"]["reason"]
        assert_equal "Englisch", result.data[:facts]["original_language"]["value"]
      end

      test "a zero or negative word count is invalid and not applied" do
        result = apply(word_count: {value: 0, confidence: "low"})

        assert_nil @book.reload.word_count
        assert_equal "invalid", result.data[:facts]["word_count"]["reason"]
      end

      test "a page range that is not a number or a range is invalid" do
        result = apply(page_range: {value: "about 300", confidence: "low"})

        assert_nil @book.reload.page_range
        assert_equal "invalid", result.data[:facts]["page_range"]["reason"]
      end

      test "a range page_range is accepted" do
        apply(page_range: {value: "250-350", confidence: "medium"})

        assert_equal "250-350", @book.reload.page_range
      end

      test "alternate titles are unioned, case-insensitively, excluding the title itself" do
        @book.update!(alternate_titles: ["Fresh"])

        result = apply(alternate_titles: {value: ["fresh", "A FRESH BOOK", "Frisch"], confidence: "medium"})

        assert_equal ["Fresh", "Frisch"], @book.reload.alternate_titles
        assert_equal "filled", result.data[:facts]["alternate_titles"]["reason"]
        assert_equal ["Frisch"], result.data[:facts]["alternate_titles"]["value"]
      end

      test "alternate titles with nothing new are already_set" do
        @book.update!(alternate_titles: ["Fresh"])

        result = apply

        assert_equal "already_set", result.data[:facts]["alternate_titles"]["reason"]
      end

      test "human-cleared alternate_titles are never refilled" do
        human_clear!("alternate_titles", [])

        result = apply

        assert_equal [], @book.reload.alternate_titles
        assert_equal "human_cleared", result.data[:facts]["alternate_titles"]["reason"]
        refute result.data[:facts]["alternate_titles"]["applied"]
      end

      test "origin countries are added when the book has none" do
        result = apply

        assert_equal [books_countries(:french)], @book.reload.countries.to_a
        assert_equal "filled", result.data[:facts]["origin_countries"]["reason"]
        assert_equal [], result.data[:facts]["origin_countries"]["unmatched"]
      end

      test "origin countries are left alone when the book already has some" do
        @book.book_countries.create!(country: books_countries(:japanese))

        result = apply

        assert_equal [books_countries(:japanese)], @book.reload.countries.to_a
        assert_equal "already_set", result.data[:facts]["origin_countries"]["reason"]
      end

      test "origin countries de-duplicate case-insensitively before matching" do
        result = apply(origin_countries: {value: ["French", "french", "FRENCH"], confidence: "high"})

        assert_equal [books_countries(:french)], @book.reload.countries.to_a
        assert_equal 1, @book.book_countries.count
        assert_equal "filled", result.data[:facts]["origin_countries"]["reason"]
        assert_equal ["French"], result.data[:facts]["origin_countries"]["value"]
      end

      test "origin countries with no match record the unmatched names and create nothing" do
        result = apply(origin_countries: {value: ["USA", "Martian"], confidence: "high"})

        assert_empty @book.reload.countries
        assert_equal "no_match", result.data[:facts]["origin_countries"]["reason"]
        assert_equal ["USA", "Martian"], result.data[:facts]["origin_countries"]["unmatched"]
      end

      test "book type and series are recorded but not applied" do
        result = apply(series_name: {value: "The Fresh Cycle", confidence: "medium"}, series_number: {value: 2, confidence: "medium"})

        %w[book_type series_name series_number].each do |name|
          assert_equal "not_applied_yet", result.data[:facts][name]["reason"], name
          refute result.data[:facts][name]["applied"], name
        end
        assert_equal "fiction", result.data[:facts]["book_type"]["value"]
        assert_equal "The Fresh Cycle", result.data[:facts]["series_name"]["value"]
        assert_empty @book.reload.series
      end

      test "first_published_year_estimated is recorded alongside the year" do
        result = apply(first_published_year_estimated: true)

        assert_equal true, result.data[:facts]["first_published_year_estimated"]["value"]
        assert_equal "not_applied_yet", result.data[:facts]["first_published_year_estimated"]["reason"]
      end

      test "writes the description as an ai_generated row with the first citation" do
        result = apply(citations: ["https://example.org/source", "https://example.org/other"])

        row = @book.descriptions.reload.find_by(source: :ai_generated)
        assert_equal "A paragraph about a fresh book.", row.content
        assert_equal "https://example.org/source", row.source_url
        assert_equal "filled", result.data[:facts]["description"]["reason"]
        assert_equal({"spoilers" => false}, result.data[:facts]["description"]["review"])
      end

      test "does not write a second ai_generated description" do
        @book.assign_description(source: :ai_generated, content: "Already here.").save!

        result = apply

        assert_equal 1, @book.descriptions.reload.where(source: :ai_generated).count
        assert_equal "Already here.", @book.descriptions.find_by(source: :ai_generated).content
        assert_equal "already_set", result.data[:facts]["description"]["reason"]
      end

      test "a manual description does not block the ai_generated row" do
        @book.assign_description(source: :manual, content: "Hand written.").save!

        apply

        assert_equal 2, @book.descriptions.reload.count
        assert_equal "Hand written.", @book.primary_description.content
      end

      test "a description with a rejection reason is recorded and not written" do
        result = apply(description: {text: "Bad -- text", review: {"spoilers" => true}, reason: "rejected"})

        assert_empty @book.descriptions.reload
        assert_equal "rejected", result.data[:facts]["description"]["reason"]
        refute result.data[:facts]["description"]["applied"]
        assert_equal({"spoilers" => true}, result.data[:facts]["description"]["review"])
      end

      test "a blank description text is recorded as null, not filled" do
        result = apply(description: {text: "   ", review: nil, reason: nil})

        assert_empty @book.descriptions.reload
        assert_equal "null", result.data[:facts]["description"]["reason"]
        refute result.data[:facts]["description"]["applied"]
      end

      test "no description at all is recorded as null" do
        result = apply({description: {value: nil, confidence: "low"}}, description: nil)

        assert_empty @book.descriptions.reload
        assert_equal "null", result.data[:facts]["description"]["reason"]
      end

      test "never touches the legacy description column" do
        apply

        assert_nil @book.reload.description
      end

      test "saves the book once with all fills" do
        ::Books::Book.any_instance.expects(:save!).once.returns(true)

        apply
      end

      test "applied lists only what changed" do
        @book.update!(first_published_year: 1950)

        result = apply

        refute_includes result.data[:applied], "first_published_year"
        assert_includes result.data[:applied], "word_count"
        assert_includes result.data[:applied], "description"
      end
    end
  end
end
