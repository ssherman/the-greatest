# frozen_string_literal: true

module Services
  module Books
    # Fields a human deliberately blanked: through the corrections flow (the
    # column target accepts blanks on purpose) or through the admin UI or API,
    # which record a ClearedField row. An AI or scraper refill would repeat the
    # mistake the clear removed.
    class HumanClearedFields
      # The SQL twin of `for`, as a fragment correlated on books_books.id: true
      # when no human cleared field_name. A correction counts as a clear when it
      # is applied and its new_value is SQL NULL, JSON null or a string that is
      # empty once trimmed. field_name is bound, never interpolated.
      def self.not_cleared_sql(field_name)
        ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, field_name, field_name])
          NOT EXISTS (
            SELECT 1 FROM cleared_fields
            WHERE cleared_fields.clearable_type = 'Books::Book'
              AND cleared_fields.clearable_id = books_books.id
              AND cleared_fields.field_name = ?
          ) AND NOT EXISTS (
            SELECT 1 FROM correction_fields
            JOIN corrections ON corrections.id = correction_fields.correction_id
            WHERE corrections.correctable_type = 'Books::Book'
              AND corrections.correctable_id = books_books.id
              AND correction_fields.field_name = ?
              AND correction_fields.status = #{CorrectionField.statuses.fetch("applied")}
              AND (
                correction_fields.new_value IS NULL
                OR jsonb_typeof(correction_fields.new_value) = 'null'
                OR (jsonb_typeof(correction_fields.new_value) = 'string' AND btrim(correction_fields.new_value #>> '{}') = '')
              )
          )
        SQL
      end

      def self.for(book)
        CorrectionField.applied
          .joins(:correction)
          .where(corrections: {correctable_type: "Books::Book", correctable_id: book.id})
          .pluck(:field_name, :new_value)
          .select { |_name, value| value.blank? }
          .map(&:first)
          .to_set
          .merge(book.cleared_fields.pluck(:field_name))
      end
    end
  end
end
