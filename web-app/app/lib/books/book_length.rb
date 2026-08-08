# frozen_string_literal: true

module Books
  # Ports the legacy site's two book_length derivation rules so books created
  # after the migration still get a length. page_range wins outright: legacy
  # runs the two rules in independent before_save callbacks, each guarded on
  # book_length being blank, so a page_range that fails to parse leaves the
  # length unset rather than falling through to word_count.
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
