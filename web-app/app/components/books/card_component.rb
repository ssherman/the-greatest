# frozen_string_literal: true

class Books::CardComponent < ViewComponent::Base
  EAGER_IMAGE_COUNT = 6

  # The grid this card is designed for. Every books grid references it, so My
  # Lists cannot drift away from the homepage the way it did before.
  GRID_CONTAINER_CLASS = "grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 " \
    "lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-6"

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
