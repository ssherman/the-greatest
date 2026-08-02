# frozen_string_literal: true

class Books::CardComponent < ViewComponent::Base
  EAGER_IMAGE_COUNT = 6

  def initialize(book:, rank: nil, index: nil)
    @book = book
    @rank = rank
    @index = index
  end

  private

  attr_reader :book, :rank, :index

  def author_names
    book.book_authors.map { |book_author| book_author.author.name }.join(", ")
  end

  def cover
    @cover ||= book.primary_image if book.primary_image&.file&.attached?
  end

  # A caller that omits index gets lazy/auto rather than eager/high. Defaulting
  # an unknown position to "above the fold" makes every card in a 100-item grid
  # fetch its cover eagerly at high priority.
  def above_fold?
    index.present? && index < EAGER_IMAGE_COUNT
  end

  def loading_strategy
    above_fold? ? "eager" : "lazy"
  end

  def fetch_priority
    above_fold? ? "high" : "auto"
  end
end
