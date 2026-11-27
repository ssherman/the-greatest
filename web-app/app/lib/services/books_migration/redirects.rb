module Services
  module BooksMigration
    # Read side of record_redirects (spec §4), loaded once per sync run, and again when a merge commits
    # while the run is going (stale?).
    class Redirects
      # The marker is read before the rows: a write landing between the two then shows as stale (one
      # needless reload) rather than as current (a merge never seen).
      def self.load
        marker = self.marker
        new(RecordRedirect.pluck(:item_type, :from_id, :to_id), marker: marker)
      end

      # Cheap fingerprint of record_redirects: a merge or delete inserts a row (count, max id), and a repoint
      # or a merge overwriting a delete stamps updated_at (RedirectRecorder, Apply::Mixed).
      def self.marker
        RecordRedirect.pick(Arel.sql("COUNT(*)"), Arel.sql("MAX(id)"), Arel.sql("MAX(updated_at)"))
      end

      # rows: [[item_type, from_id, to_id], ...]; to_id nil means deleted. marker: what self.marker read
      # with them; nil for rows that did not come from the table, which are never stale.
      def initialize(rows, marker: nil)
        @targets = rows.to_h { |item_type, from_id, to_id| [[item_type, from_id], to_id] }
        @marker = marker
      end

      # record_redirects changed since these were read: a merge or delete committed in the meantime.
      def stale?
        !@marker.nil? && self.class.marker != @marker
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

      # One step of a redirect: the id +id+ was merged into, or nil when it was deleted (or never redirected;
      # tell the two apart with redirected?). resolve follows the whole chain; this is for callers that must
      # stop partway.
      def target(item_type, id)
        @targets[[item_type, id]]
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
