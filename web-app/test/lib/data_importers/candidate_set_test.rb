require "test_helper"

module DataImporters
  class CandidateSetTest < ActiveSupport::TestCase
    def setup
      @book = books_books(:war_and_peace)
      @other = books_books(:crime_and_punishment)
    end

    test "merges two candidates for the same local record into one" do
      set = CandidateSet.new
      set.add(Candidate.new(record: @book, sources: [:exact]))
      set.add(Candidate.new(record: @book, sources: [:opensearch], scores: {opensearch: 9.1}))

      assert_equal 1, set.size
      assert_equal [:exact, :opensearch], set.to_a.first.sources
      assert_equal({opensearch: 9.1}, set.to_a.first.scores)
    end

    test "merges two candidates for the same external key into one" do
      set = CandidateSet.new
      set.add(Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library]))
      set.add(Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:musicbrainz]))

      assert_equal 1, set.size
      assert_equal [:open_library, :musicbrainz], set.to_a.first.sources
    end

    test "an external candidate that later turns out to be a known local record folds into the local one" do
      set = CandidateSet.new
      set.add(Candidate.new(record: @book, sources: [:opensearch]))
      set.add(Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library]))
      set.add(Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library, sources: [:open_library]))

      assert_equal 1, set.size
      merged = set.to_a.first
      assert_equal @book, merged.record
      assert_equal "OL1W", merged.external_key
      assert_equal [:opensearch, :open_library], merged.sources
    end

    test "keeps distinct records and distinct keys apart, in insertion order" do
      set = CandidateSet.new
      set.add(Candidate.new(record: @book, sources: [:exact]))
      set.add(Candidate.new(record: @other, sources: [:exact]))
      set.add(Candidate.new(external_key: "OL9W", external_source: :open_library, sources: [:open_library]))

      assert_equal 3, set.size
      assert_equal [@book, @other, nil], set.to_a.map(&:record)
      assert_equal [@book, @other], set.locals.map(&:record)
    end

    test "empty? and size" do
      set = CandidateSet.new

      assert set.empty?
      set.add(Candidate.new(record: @book))
      assert_not set.empty?
      assert_equal 1, set.size
    end
  end
end
