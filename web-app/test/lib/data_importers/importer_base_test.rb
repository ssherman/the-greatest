require "test_helper"

module DataImporters
  class ImporterBaseTest < ActiveSupport::TestCase
    class FakeQuery
      attr_reader :title

      def initialize(title = "Seeded")
        @title = title
      end

      def valid? = true
    end

    class FakeFinder
      attr_reader :calls

      def initialize(match)
        @match = match
        @calls = []
      end

      def call(**kwargs)
        @calls << kwargs
        @match
      end
    end

    class RecordingProvider < DataImporters::ProviderBase
      attr_reader :received

      def populate(item, query:, match: nil)
        @received = {item: item, query: query, match: match}
        item.title = "#{item.title} (provided)"
        success_result(data_populated: [:title])
      end
    end

    class TestImporter < DataImporters::ImporterBase
      attr_reader :fake_finder, :provider

      def initialize(match:)
        @fake_finder = FakeFinder.new(match)
        @provider = RecordingProvider.new
      end

      protected

      def finder = fake_finder

      def providers = [provider]

      def initialize_item(query) = ::Books::Book.new(title: query.title)
    end

    def setup
      @existing = books_books(:war_and_peace)
      @query = FakeQuery.new
    end

    def decision_for(match)
      MatchDecision.create!(finder: "F", record: match.record, outcome: match.outcome, confidence: match.confidence, decided_by: match.decided_by)
    end

    test "a matched finder result returns the existing record, runs no provider, and carries the match" do
      match = Match.new(outcome: :matched, record: @existing, confidence: :certain, decided_by: :identifier)
      importer = TestImporter.new(match: match)

      result = importer.call(query: @query)

      assert result.success?
      assert_equal @existing, result.item
      assert_same match, result.match
      assert_nil importer.provider.received
      assert_equal [{query: @query, verify: false, subject: nil}], importer.fake_finder.calls
    end

    test "subject and verify are passed through to the finder" do
      subject = list_items(:music_albums_item)
      match = Match.new(outcome: :matched, record: @existing, confidence: :certain, decided_by: :identifier)
      importer = TestImporter.new(match: match)

      importer.call(query: @query, subject: subject, verify: true)

      assert_equal [{query: @query, verify: true, subject: subject}], importer.fake_finder.calls
    end

    test "force_providers runs the providers on the existing record and hands them the match" do
      match = Match.new(outcome: :matched, record: @existing, confidence: :certain, decided_by: :identifier)
      importer = TestImporter.new(match: match)

      result = importer.call(query: @query, force_providers: true)

      assert_equal @existing, result.item
      assert_same match, importer.provider.received[:match]
      assert_equal @query, importer.provider.received[:query]
    end

    test "an unmatched finder result creates the record, hands providers the match, and points the decision at the new record" do
      match = Match.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule)
      match.decision = decision_for(match)
      importer = TestImporter.new(match: match)

      result = importer.call(query: @query)

      assert result.success?
      assert result.item.persisted?
      assert_equal "Seeded (provided)", result.item.title
      assert_same match, importer.provider.received[:match]
      assert_equal result.item, match.decision.reload.record
      assert_same match, result.match
    end

    test "an unmatched result whose providers all fail leaves the decision without a record" do
      match = Match.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule)
      match.decision = decision_for(match)
      importer = TestImporter.new(match: match)
      importer.provider.stubs(:populate).returns(ProviderResult.failure(provider: "RecordingProvider", errors: ["nope"]))

      result = importer.call(query: @query)

      assert result.failure?
      assert_not result.item.persisted?
      assert_nil match.decision.reload.record
    end

    test "an item-based import skips the finder and hands providers a nil match" do
      importer = TestImporter.new(match: nil)

      result = importer.call(item: @existing)

      assert_equal [], importer.fake_finder.calls
      assert_nil importer.provider.received[:match]
      assert_nil result.match
    end

    test "ImportResult#summary names the match outcome and confidence when there is one" do
      match = Match.new(outcome: :matched, record: @existing, confidence: :high, decided_by: :rule)
      result = ImportResult.new(item: @existing, provider_results: [], success: true, match: match)

      assert_equal :matched, result.summary[:match_outcome]
      assert_equal :high, result.summary[:match_confidence]
      assert_nil ImportResult.new(item: nil, provider_results: [], success: false).summary[:match_outcome]
    end
  end
end
