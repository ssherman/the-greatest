# frozen_string_literal: true

# The read side of a ranking archive. An archive stores three parallel arrays
# that are never rewritten, so a book that was merged or deleted after capture
# is resolved here, at read time, through record_redirects: a live id is shown,
# a merged id is shown as its surviving book at the archived position, a book
# appears once per archive at its best slot, and anything gone is skipped.
#
# The whole-archive work (finding each book's best slot) is on integer ids
# only. Records are loaded for the requested page alone.
#
# Model constants are root-anchored: Services::RankingConfiguration is an
# existing module, so a bare model name could resolve to a service namespace.
module Services
  module RankingArchives
    class Entries
      Entry = Struct.new(:item, :rank, :score, keyword_init: true)

      def self.call(archive:, offset:, limit:, preload: [])
        new(archive: archive, offset: offset, limit: limit, preload: preload).call
      end

      def initialize(archive:, offset:, limit:, preload: [])
        @archive = archive
        @offset = offset
        @limit = limit
        @preload = preload
        @item_class = archive.item_class
        @item_type = archive.class.item_type
      end

      def call
        @ids, @ranks, @scores = %i[item_ids positions scores].map { |attr| @archive.public_send(attr)[@offset, @limit] || [] }
        resolved = resolve(@ids)
        kept = resolved.each_with_index.select { |id, i| id && best_slot(id, resolved) == @offset + i }
        records = @item_class.where(id: kept.map(&:first)).preload(@preload).index_by(&:id)
        kept.filter_map do |id, i|
          records[id] && Entry.new(item: records[id], rank: @ranks[i], score: @scores[i])
        end
      end

      private

      # Each page id mapped to the live id it shows, or nil to skip it.
      def resolve(ids)
        live = @item_class.where(id: ids).pluck(:id).to_set
        forward = ::RecordRedirect.where(item_type: @item_type, from_id: ids.reject { |id| live.include?(id) })
          .where.not(to_id: nil).pluck(:from_id, :to_id).to_h
        ids.map { |id| live.include?(id) ? id : forward[id] }
      end

      # The earliest archive index of a book or of any id redirected to it.
      def best_slot(id, resolved)
        aliases = aliases_for(resolved)
        [id, *aliases.fetch(id, [])].filter_map { |candidate| first_index[candidate] }.min
      end

      def aliases_for(resolved)
        @aliases ||= ::RecordRedirect.where(item_type: @item_type, to_id: resolved.compact.uniq)
          .pluck(:to_id, :from_id).group_by(&:first).transform_values { |rows| rows.map(&:last) }
      end

      def first_index
        @first_index ||= {}.tap do |map|
          @archive.item_ids.each_with_index { |id, i| map[id] ||= i }
        end
      end
    end
  end
end
