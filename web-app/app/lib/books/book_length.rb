# frozen_string_literal: true

module Books
  # Ports the legacy site's book_length derivation so books created after the
  # migration still get a length. The "page_range wins, fall back to word_count
  # only when page_range is blank" rule is ported from legacy's bulk backfill
  # job (set_missing_book_lengths_from_word_count), which explicitly scopes on
  # page_range: [nil, ""] -- that job, not legacy's write-time callbacks, is
  # what populated word-count-derived lengths at scale. Legacy's two callbacks
  # are independent and can disagree with this: set_book_length_from_word_count
  # has no page_range guard at all, so it can fall through to word_count even
  # when a present page_range failed to parse.
  class BookLength
    WORDS_PER_PAGE = 275.0

    def self.call(page_range:, word_count:)
      pages = pages_from_range(page_range)
      pages ||= (word_count / WORDS_PER_PAGE).round if page_range.blank? && word_count.present?
      return nil if pages.nil?

      band(pages)
    end

    # Legacy names this extract_max_pages, but a hyphenated range resolves to the
    # rounded MIDPOINT of its bounds, not the maximum.
    def self.pages_from_range(page_range)
      return nil if page_range.blank?
      return nil if page_range.match?(/[a-zA-Z]/)

      unless page_range.include?("-")
        number = page_range.to_i
        return number.positive? ? number : nil
      end

      numbers = page_range.split("-").map(&:to_i)
      return nil if numbers.empty? || numbers.any?(&:zero?)

      ((numbers.min + numbers.max) / 2.0).round
    end
    private_class_method :pages_from_range

    def self.band(pages)
      case pages
      when 0..149 then :very_short
      when 150..250 then :short
      when 251..350 then :medium
      when 351..500 then :moderate
      when 501..1000 then :long
      else :very_long
      end
    end
    private_class_method :band
  end
end
