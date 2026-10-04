# frozen_string_literal: true

module Books
  # The Rails twin of normalize_isbn in data-sources/src/common/normalize.py:
  # drop every non-alphanumeric character, check the checksum, derive the
  # other form. Unlike the Python twin it returns nil for a failed checksum
  # instead of flagging it, because an import never stores an invalid ISBN
  # (Goodreads import spec §4).
  module Isbn
    Normalized = Data.define(:isbn13, :isbn10)

    def self.normalize(raw)
      cleaned = raw.to_s.gsub(/[^0-9A-Za-z]/, "").upcase

      if cleaned.match?(/\A\d{9}[\dX]\z/)
        return nil unless isbn10_check_digit(cleaned[0, 9]) == cleaned[9]

        body13 = "978#{cleaned[0, 9]}"
        Normalized.new(isbn13: body13 + isbn13_check_digit(body13), isbn10: cleaned)
      elsif cleaned.match?(/\A\d{13}\z/)
        return nil unless isbn13_check_digit(cleaned[0, 12]) == cleaned[12]

        body10 = cleaned[3, 9]
        Normalized.new(isbn13: cleaned, isbn10: cleaned.start_with?("978") ? body10 + isbn10_check_digit(body10) : nil)
      end
    end

    def self.isbn10_check_digit(body)
      total = body.chars.each_with_index.sum { |digit, index| (10 - index) * digit.to_i }
      remainder = (11 - (total % 11)) % 11
      (remainder == 10) ? "X" : remainder.to_s
    end

    def self.isbn13_check_digit(body)
      total = body.chars.each_with_index.sum { |digit, index| digit.to_i * (index.even? ? 1 : 3) }
      ((10 - (total % 10)) % 10).to_s
    end

    private_class_method :isbn10_check_digit, :isbn13_check_digit
  end
end
