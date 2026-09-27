# frozen_string_literal: true

require "test_helper"

module Services
  module ExternalRecords
    class StoreTest < ActiveSupport::TestCase
      def write(source_id, payload: {"id" => source_id}, raw: "{}", schema_version: 1)
        Store.write(source: :wikidata, source_id: source_id, payload: payload, raw: raw, schema_version: schema_version)
      end

      test "write creates a row with the payload, the gzipped raw body and the schema version" do
        record = write("Q7243", payload: {"id" => "Q7243", "label" => "Leo Tolstoy"}, raw: '{"id":"Q7243"}')

        assert record.persisted?
        assert_equal "Leo Tolstoy", record.payload["label"]
        assert_equal '{"id":"Q7243"}', record.reload.raw_text
        assert_equal 1, record.schema_version
        assert_not_nil record.fetched_at
      end

      test "write updates the existing row for the same source and id" do
        write("Q7243", payload: {"label" => "old"})

        assert_no_difference -> { ::ExternalRecord.count } do
          write("Q7243", payload: {"label" => "new"}, schema_version: 2)
        end
        record = ::ExternalRecord.find_by!(source: :wikidata, source_id: "Q7243")
        assert_equal ["new", 2], [record.payload["label"], record.schema_version]
      end

      test "write returns the winner's row when another worker inserted it first" do
        winner = write("Q42")
        loser = ::ExternalRecord.new(source: :wikidata, source_id: "Q42")
        ::ExternalRecord.stubs(:find_or_initialize_by).returns(loser)
        loser.stubs(:save!).raises(ActiveRecord::RecordNotUnique)

        assert_equal winner.id, write("Q42").id
      end

      test "find returns a row only at the current schema version and for the right source" do
        write("Q1", schema_version: 1)

        assert_not_nil Store.find(source: :wikidata, source_id: "Q1", schema_version: 1)
        assert_nil Store.find(source: :wikidata, source_id: "Q1", schema_version: 2)
        assert_nil Store.find(source: :wikipedia, source_id: "Q1", schema_version: 1)
        assert_nil Store.find(source: :wikidata, source_id: "Q2", schema_version: 1)
      end

      test "find_all maps each held id to its row in one query" do
        write("Q1")
        write("Q2")

        found = Store.find_all(source: :wikidata, source_ids: ["Q1", "Q2", "Q3"], schema_version: 1)

        assert_equal ["Q1", "Q2"], found.keys.sort
        assert_equal({}, Store.find_all(source: :wikidata, source_ids: [], schema_version: 1))
      end
    end
  end
end
