# frozen_string_literal: true

module Books
  module PublisherIntake
    # Sets status and hold_reason from a reading's facts (symbol keys). First
    # match wins. A false hold loses a real book; a false pass only lets a
    # three-in-one volume through, so each rule leans toward ready.
    module Hold
      TITLE_PLACEHOLDER = /\A\s*(untitled|to be confirmed|tbc|tbd|title to be announced)\b/i
      CONTRIBUTOR_PLACEHOLDER = /\A(to be confirmed|tbc|tbd|author to be announced)\z/i
      NON_BOOK_FORMAT = /\b(calendar|journal|notebook|planner|cards?|deck|puzzle|stationery|sticker|toy|kit|poster|game)\b/i
      SET_FORMAT = /\b(box(ed)?[\s-]?set|bundle)\b/i
      BOOK_COUNT = /\A\d+\s+books?\z/i
      ENGLISH = /\A(en|eng|english)\z|\Aen-/i

      def self.call(facts)
        reason = (incomplete?(facts) && :incomplete) ||
          (placeholder?(facts) && :placeholder) ||
          (non_english?(facts) && :non_english) ||
          (not_a_book?(facts) && :not_a_book) ||
          (set?(facts) && :set)
        reason ? [:held, reason] : [:ready, nil]
      end

      def self.incomplete?(facts)
        names = Array(facts[:contributors]).map { |c| c[:name] }
        isbns = formats(facts).map { |f| f[:isbn13] }
        facts[:title].blank? || names.none?(&:present?) || isbns.none?(&:present?)
      end

      def self.placeholder?(facts)
        return true if facts[:title].to_s.match?(TITLE_PLACEHOLDER)

        contributors = Array(facts[:contributors])
        contributors.size == 1 && contributors.first[:name].to_s.strip.match?(CONTRIBUTOR_PLACEHOLDER)
      end

      def self.non_english?(facts)
        language = facts[:language].to_s.strip
        language.present? && !language.match?(ENGLISH)
      end

      def self.not_a_book?(facts)
        all = formats(facts)
        all.any? && all.all? { |f| f[:format_label].to_s.match?(NON_BOOK_FORMAT) }
      end

      # The series name is never examined: "Omnibus Editions" as a series does
      # not make one volume a set. A match that is only a series-name word
      # ("Trilogy", "Collection") is a description, not a bundle.
      def self.set?(facts)
        return true if formats(facts).any? { |f| f[:format_label].to_s.match?(SET_FORMAT) }
        return true if facts[:title].to_s.match?(Services::Books::AmazonBookCheck::NUMBER_RANGE)

        text = "#{facts[:title]} #{facts[:subtitle]}"
        words = text.to_enum(:scan, Services::Books::Verification::EditionCheck::SET_WORDS).map { Regexp.last_match(0).downcase }
        # "1001 Books You Must Read" counts books; titles that count books are books.
        words.reject! { |word| word.match?(BOOK_COUNT) }
        (words - Services::Books::AmazonBookCheck::SERIES_NAME_WORDS).any?
      end

      def self.formats(facts) = Array(facts[:formats])

      private_class_method :incomplete?, :placeholder?, :non_english?, :not_a_book?, :set?, :formats
    end
  end
end
