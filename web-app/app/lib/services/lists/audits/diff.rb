module Services
  module Lists
    module Audits
      # Compares two Snapshot hashes: changed fields (from/to) and penalties
      # attached or detached between them.
      class Diff
        def self.call(before:, after:)
          before_fields = before["fields"] || {}
          after_fields = after["fields"] || {}
          fields = (before_fields.keys | after_fields.keys).each_with_object({}) do |field, changed|
            next if before_fields[field] == after_fields[field]
            changed[field] = {"from" => before_fields[field], "to" => after_fields[field]}
          end

          before_penalties = before["penalties"] || []
          after_penalties = after["penalties"] || []
          before_ids = before_penalties.map { |p| p["id"] }
          after_ids = after_penalties.map { |p| p["id"] }

          items_added, items_removed, items_changed = item_changes(before, after)

          {
            "fields" => fields,
            "penalties_attached" => after_penalties.reject { |p| before_ids.include?(p["id"]) },
            "penalties_detached" => before_penalties.reject { |p| after_ids.include?(p["id"]) },
            "items_added" => items_added,
            "items_removed" => items_removed,
            "items_changed" => items_changed
          }
        end

        # Audits started before rows were snapshotted have no "items" key on
        # their before side; comparing against nothing would report every row
        # as added, so rows are compared only when both snapshots carry them.
        def self.item_changes(before, after)
          return [[], [], []] unless before.key?("items") && after.key?("items")

          before_rows = before["items"].index_by { |r| r["id"] }
          after_rows = after["items"].index_by { |r| r["id"] }
          changed = (before_rows.keys & after_rows.keys).filter_map do |id|
            change = %w[book_id position].each_with_object({"id" => id}) do |key, memo|
              next if before_rows[id][key] == after_rows[id][key]
              memo[key] = {"from" => before_rows[id][key], "to" => after_rows[id][key]}
            end
            change if change.size > 1
          end
          [
            after["items"].reject { |r| before_rows.key?(r["id"]) },
            before["items"].reject { |r| after_rows.key?(r["id"]) },
            changed
          ]
        end
        private_class_method :item_changes

        def self.empty?(diff)
          diff["fields"].blank? && diff["penalties_attached"].blank? && diff["penalties_detached"].blank? &&
            diff["items_added"].blank? && diff["items_removed"].blank? && diff["items_changed"].blank?
        end
      end
    end
  end
end
