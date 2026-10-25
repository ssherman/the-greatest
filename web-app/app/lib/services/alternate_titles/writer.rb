# frozen_string_literal: true

module Services
  module AlternateTitles
    # The one way to change a record's alternate titles. Rows in
    # alternate_titles are the truth; the alternate_titles
    # column is a copy of the record's kept and review rows (ordered by id) that
    # every method here re-assigns. Only `decide` saves the record; the other
    # methods leave that to the caller so they can ride its own save.
    #
    # A removed title is never added back by legacy, merge or ai_enrichment.
    # Only admin and correction may reinstate one.
    class Writer
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      REMOVED_BY = {admin: "removed by admin", correction: "removed by correction"}.freeze
      KEPT_BY_ADMIN = "kept by admin"
      REINSTATING_SOURCES = %i[admin correction].freeze
      VERDICT_COLUMNS = %w[status reason verdict category confidence ai_chat_id decided_by
        decided_by_user_id decided_at judged_at undo_checked_at].freeze

      class << self
        def add(record:, titles:, source:)
          Backfill.call(record)
          data = {added: [], reinstated: [], skipped_removed: []}
          ::AlternateTitle.transaction { write_titles(record, titles, source, data) }
          assign_copy(record)
          success(data)
        end

        def replace(record:, titles:, source:, user: nil)
          unless REINSTATING_SOURCES.include?(source.to_sym)
            raise ArgumentError, "replace needs source :admin or :correction, got #{source.inspect}"
          end
          source = source.to_sym

          Backfill.call(record)
          data = {added: [], reinstated: [], removed: []}
          ::AlternateTitle.transaction do
            incoming = unique_titles(titles).reject { |normalized, _| normalized == main_normalized(record) }
            now = Time.current
            rows_for(record).listed.each do |row|
              next if incoming.key?(row.normalized_title)
              row.update!(status: :removed, reason: REMOVED_BY.fetch(source), decided_by: source,
                decided_by_user_id: user&.id, decided_at: now)
              data[:removed] << row.title
            end
            write_titles(record, incoming.values, source, data, user: user)
            rows_for(record).where(normalized_title: incoming.keys).each do |row|
              spelling = incoming[row.normalized_title]
              row.update!(title: spelling) if row.title != spelling
            end
          end
          assign_copy(record)
          success(data)
        end

        def decide(row:, status:, user: nil)
          status = status.to_sym
          raise ArgumentError, "status must be :kept or :removed" unless %i[kept removed].include?(status)

          attrs = {status: status, decided_by: :admin, decided_by_user_id: user&.id, decided_at: Time.current}
          default_reason = (status == :removed) ? REMOVED_BY[:admin] : KEPT_BY_ADMIN
          attrs[:reason] = default_reason if row.reason.blank? || generated_reason?(row.reason)
          record = row.titleable
          ::AlternateTitle.transaction do
            row.update!(attrs)
            assign_copy(record)
            record.save!
          end
          success({row: row})
        end

        # Moves every row of source to target (merger). Returns the
        # titles that became listed on the target.
        def move(source:, target:)
          Backfill.call(source)
          Backfill.call(target)
          before = listed_titles(target)
          ::AlternateTitle.transaction do
            target_rows = rows_for(target).index_by(&:normalized_title)
            target_main = main_normalized(target)
            rows_for(source).order(:id).each do |row|
              if (existing = target_rows[row.normalized_title])
                carry_removal(row, existing)
                row.destroy!
              elsif row.normalized_title == target_main
                row.destroy!
              else
                row.update_columns(titleable_id: target.id)
                target_rows[row.normalized_title] = row
              end
            end
            write_titles(target, [source.title], :merge, {added: [], reinstated: [], skipped_removed: []})
          end
          assign_copy(target)
          listed_titles(target) - before
        end

        def listed_titles(record)
          rows_for(record).listed.pluck(:title)
        end

        private

        def rows_for(record) = ::AlternateTitle.where(titleable: record)

        def generated_reason?(reason) = (REMOVED_BY.values + [KEPT_BY_ADMIN]).include?(reason)

        def success(data) = Result.new(success?: true, data: data, errors: [])

        def normalize(title) = ::AlternateTitle.normalize(title)

        def main_normalized(record) = normalize(record.title)

        def assign_copy(record)
          return unless record.has_attribute?(:alternate_titles)

          record.alternate_titles = listed_titles(record)
        end

        # normalized form => first spelling
        def unique_titles(titles)
          Array(titles).each_with_object({}) do |title, seen|
            normalized = normalize(title)
            seen[normalized] ||= title.to_s.strip if normalized.present?
          end
        end

        def write_titles(record, titles, source, data, user: nil)
          source = source.to_sym
          main = main_normalized(record)
          existing = rows_for(record).index_by(&:normalized_title)
          now = Time.current
          unique_titles(titles).each do |normalized, title|
            next if normalized == main

            row = existing[normalized]
            if row.nil?
              existing[normalized] = ::AlternateTitle.create!(titleable: record, title: title, source: source, status: :kept)
              data[:added] << title
            elsif row.removed?
              if REINSTATING_SOURCES.include?(source)
                attrs = {status: :kept, source: source, decided_by: source,
                         decided_by_user_id: user&.id, decided_at: now}
                attrs[:reason] = nil if generated_reason?(row.reason)
                row.update!(attrs)
                data[:reinstated] << row.title
              else
                data[:skipped_removed] << title
              end
            end
          end
        end

        # Removed wins: when either side of a duplicate is removed the target's
        # row ends up removed, with the source's verdict if the source was the
        # removed one.
        def carry_removal(source_row, target_row)
          return unless source_row.removed? && !target_row.removed?

          # The target's removal is new, so it is not stamped as checked, whatever the source's was.
          target_row.update_columns(source_row.attributes.slice(*(VERDICT_COLUMNS - ["undo_checked_at"]))
            .merge("undo_checked_at" => nil, "updated_at" => Time.current))
        end
      end
    end
  end
end
