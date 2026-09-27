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

    class FailingProvider < DataImporters::ProviderBase
      def populate(item, query:, match: nil)
        failure_result(errors: ["service down"])
      end
    end

    class FailingImporter < TestImporter
      def initialize(match:)
        super
        @provider = FailingProvider.new
      end
    end

    class SaveFirstImporter < FailingImporter
      protected

      def save_before_providers? = true
    end

    def unmatched_match
      match = Match.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule)
      match.decision = decision_for(match)
      match
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

    test "a save-first importer keeps a new record when every provider fails, and points the decision at it" do
      match = unmatched_match

      result = SaveFirstImporter.new(match: match).call(query: FakeQuery.new("Kept"))

      assert result.item.persisted?
      assert result.created?
      assert_not result.success?
      assert_equal result.item, match.decision.reload.record
    end

    test "a default importer does not save a new record when its only provider fails" do
      result = FailingImporter.new(match: unmatched_match).call(query: FakeQuery.new("Dropped"))

      assert_not result.item.persisted?
      assert_not result.created?
    end

    test "a save-first importer does not save an invalid new item" do
      result = SaveFirstImporter.new(match: unmatched_match).call(query: FakeQuery.new(nil))

      assert_not result.item.persisted?
      assert_not result.created?
    end

    test "created? is true for a new record a provider saved and false for a matched one" do
      created = TestImporter.new(match: unmatched_match).call(query: @query)
      matched = TestImporter.new(match: Match.new(outcome: :matched, record: @existing, confidence: :certain, decided_by: :identifier)).call(query: @query)
      forced = TestImporter.new(match: Match.new(outcome: :matched, record: @existing, confidence: :certain, decided_by: :identifier)).call(query: @query, force_providers: true)

      assert created.created?
      assert_not matched.created?
      assert_not forced.created?
    end

    test "an item-based import is never created" do
      result = TestImporter.new(match: nil).call(item: @existing)

      assert_not result.created?
    end
  end
end
