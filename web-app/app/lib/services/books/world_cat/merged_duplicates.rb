# frozen_string_literal: true

module Services
  module Books
    module WorldCat
      # A later pass redirected an older OCLC number into a newer record; both come
      # back from the lookup, but they are one edition and must count once.
      module MergedDuplicates
        module_function

        def reject(records)
          merged = records.flat_map(&:merged_oclc).to_set
          records.reject { |record| merged.include?(record.oclc) }
        end
      end
    end
  end
end
