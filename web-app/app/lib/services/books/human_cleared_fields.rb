# frozen_string_literal: true

module Services
  module Books
    # Fields a human deliberately blanked through the corrections flow. The
    # column target accepts blanks on purpose, and an AI or scraper refill would
    # repeat the mistake the correction removed.
    class HumanClearedFields
      def self.for(book)
        CorrectionField.applied
          .joins(:correction)
          .where(corrections: {correctable_type: "Books::Book", correctable_id: book.id})
          .pluck(:field_name, :new_value)
          .select { |_name, value| value.blank? }
          .map(&:first)
          .to_set
      end
    end
  end
end
