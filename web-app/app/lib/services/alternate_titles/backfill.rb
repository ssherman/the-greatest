# frozen_string_literal: true

module Services
  module AlternateTitles
    # Copies a record's alternate_titles array into the alternate_titles table
    # as legacy/kept rows. Idempotent: a title already present (in any status,
    # including removed) is skipped, so a removed title is never revived.
    # A record without an alternate_titles column has nothing to copy.
    class Backfill
      def self.call(record)
        return 0 unless record.has_attribute?(:alternate_titles)

        now = Time.current
        seen = {}
        rows = record.alternate_titles.filter_map do |title|
          normalized = ::AlternateTitle.normalize(title)
          next if normalized.blank? || seen[normalized]
          seen[normalized] = true
          {titleable_type: record.class.base_class.name, titleable_id: record.id,
           title: title, normalized_title: normalized,
           source: ::AlternateTitle.sources[:legacy],
           status: ::AlternateTitle.statuses[:kept],
           created_at: now, updated_at: now}
        end
        return 0 if rows.empty?

        ::AlternateTitle.insert_all(rows, unique_by: [:titleable_type, :titleable_id, :normalized_title]).length
      end

      def self.all
        ::Books::Book.where("cardinality(alternate_titles) > 0").find_each.sum { |book| call(book) }
      end
    end
  end
end
