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

          {
            "fields" => fields,
            "penalties_attached" => after_penalties.reject { |p| before_ids.include?(p["id"]) },
            "penalties_detached" => before_penalties.reject { |p| after_ids.include?(p["id"]) }
          }
        end

        def self.empty?(diff)
          diff["fields"].blank? && diff["penalties_attached"].blank? && diff["penalties_detached"].blank?
        end
      end
    end
  end
end
