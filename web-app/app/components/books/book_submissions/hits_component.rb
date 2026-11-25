# frozen_string_literal: true

# "We already have this. Is it the one?" The books the instant check found for
# a reader's request, each with an Add to list button (the existing add-item
# endpoint), and a None of these form that sends the same input again with
# confirmed_new. The reader's input comes back in hidden fields; the view
# escapes them. Task 9 owns the final markup and the dialog around it.
class Books::BookSubmissions::HitsComponent < ViewComponent::Base
  INPUT_KEYS = %w[method goodreads_url amazon_url isbn title].freeze

  def initialize(list:, books:, input:, replaces: nil)
    @list = list
    @books = books
    @input = input
    @replaces = replaces
  end

  private

  attr_reader :list, :books, :replaces

  def author_line(book)
    book.authors.map(&:name).join(", ")
  end

  # Only strings, and an array of strings for authors: the form never sends
  # anything else, so anything else is dropped rather than echoed.
  def hidden_fields
    return [] unless @input.respond_to?(:to_h)

    values = @input.to_h.stringify_keys
    fields = INPUT_KEYS.filter_map do |key|
      ["book_submission[#{key}]", values[key]] if values[key].is_a?(String)
    end
    authors = values["authors"]
    fields += authors.grep(String).map { |name| ["book_submission[authors][]", name] } if authors.is_a?(Array)
    fields << ["replaces", @replaces.to_s] if @replaces.to_s.match?(/\A\d{1,18}\z/)
    fields
  end
end
