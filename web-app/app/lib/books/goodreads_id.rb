# frozen_string_literal: true

module Books
  # A Goodreads book id from any of the forms it arrives in: bare ("4671"),
  # slugged ("4671.The_Great_Gatsby", "32076670-ball-lightning", with or
  # without a query string) or a book page URL. 543 slug forms were carried
  # into books_work_goodreads_id from the legacy app. Only the leading
  # integer identifies the book (normalize_goodreads in
  # data-sources/src/common/normalize.py). Longer than 18 digits cannot be a
  # Goodreads id and would overflow the bigint column.
  module GoodreadsId
    SHOW_PATH = %r{/book/show/(\d+)}
    LEADING_DIGITS = /\A(\d+)/
    MAX_DIGITS = 18

    def self.normalize(raw)
      text = raw.to_s.strip
      digits = text[SHOW_PATH, 1] || text[LEADING_DIGITS, 1]
      return nil if digits.nil? || digits.length > MAX_DIGITS

      id = digits.to_i
      id.positive? ? id.to_s : nil
    end
  end
end
