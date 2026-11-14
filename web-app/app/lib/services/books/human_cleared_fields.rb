# frozen_string_literal: true

module Services
  module Books
    # Fields a human deliberately blanked: through the corrections flow (the
    # column target accepts blanks on purpose) or through the admin UI or API,
    # which record a ClearedField row. An AI or scraper refill would repeat the
    # mistake the clear removed.
    class HumanClearedFields
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
