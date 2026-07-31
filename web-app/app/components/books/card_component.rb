# frozen_string_literal: true

class Books::CardComponent < ViewComponent::Base
  def initialize(ranked_item:, index:)
    @ranked_item = ranked_item
    @index = index
  end

  private

  attr_reader :ranked_item, :index

  def book
    @book ||= ranked_item.item
  end

  def rank
    ranked_item.rank
  end

  def author_names
    book.book_authors.map { |book_author| book_author.author.name }.join(", ")
  end

  def cover
    @cover ||= book.primary_image if book.primary_image&.file&.attached?
  end

  def loading_strategy
    (index < 6) ? "eager" : "lazy"
  end

  def fetch_priority
    (index < 6) ? "high" : "auto"
  end
end
