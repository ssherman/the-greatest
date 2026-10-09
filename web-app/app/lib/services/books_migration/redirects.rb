module Services
  module BooksMigration
    # Read side of record_redirects (spec §4), loaded once per sync run.
    class Redirects
      def self.load
        new(RecordRedirect.pluck(:item_type, :from_id, :to_id))
      end

      # rows: [[item_type, from_id, to_id], ...]; to_id nil means deleted.
      def initialize(rows)
        @targets = rows.to_h { |item_type, from_id, to_id| [[item_type, from_id], to_id] }
      end

      # The id to write in place of +id+: itself when nothing happened to it, the
      # final survivor of a chain of merges, or :deleted.
      def resolve(item_type, id)
        seen = []
        current = id
        while @targets.key?([item_type, current])
          raise "record_redirects cycle for #{item_type}: #{(seen + [current]).join(" -> ")}" if seen.include?(current)

          seen << current
          current = @targets[[item_type, current]]
          return :deleted if current.nil?
        end
        current
      end

      def redirected?(item_type, id)
        @targets.key?([item_type, id])
      end

      def redirected_ids(item_type)
        @targets.each_key.filter_map { |type, from_id| from_id if type == item_type }.to_set
      end

      def counts
        RecordRedirect::ITEM_TYPES.index_with do |item_type|
          fates = @targets.select { |(type, _from_id), _to_id| type == item_type }.values
          {merged: fates.count { |to_id| !to_id.nil? }, deleted: fates.count(&:nil?)}
        end
      end
    end
  end
end
