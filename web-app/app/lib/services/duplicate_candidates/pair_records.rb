# frozen_string_literal: true

module Services
  module DuplicateCandidates
    # The records behind a page of duplicate pairs, with their finder
    # summaries (FinderBase#summarize_all: title, creators, year, ranked
    # position, list count, identifiers). One query per item type for the
    # records, and one each for the ranked positions and list counts. A record
    # a merge or delete has since removed is simply absent from :records.
    # Shared by the admin queue page and the admin API.
    #
    # Both hashes are keyed by [item_type, id].
    class PairRecords
      Result = Struct.new(:records, :summaries, keyword_init: true)

      def self.call(pairs) = new(pairs).call

      def initialize(pairs)
        @pairs = pairs
      end

      def call
        records = {}
        summaries = {}
        @pairs.group_by(&:item_type).each do |type, rows|
          entry = DataImporters::FinderRegistry.entry_for_model(type)
          next unless entry

          ids = rows.flat_map { |row| [row.item_a_id, row.item_b_id] }.uniq
          found = entry.model_class.where(id: ids).includes(:identifiers, *entry.preloads).to_a
          found_summaries = entry.finder_class.new.summarize_all(found)
          found.each do |record|
            records[[type, record.id]] = record
            summaries[[type, record.id]] = found_summaries[record.id]
          end
        end
        Result.new(records: records, summaries: summaries)
      end
    end
  end
end
