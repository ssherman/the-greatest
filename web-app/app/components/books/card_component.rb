# frozen_string_literal: true

class Books::CardComponent < ViewComponent::Base
  EAGER_IMAGE_COUNT = 6

  # The grid this card is designed for. Every books grid references it, so My
  # Lists cannot drift away from the homepage the way it did before.
  GRID_CONTAINER_CLASS = "grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 " \
    "lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-6"

  def initialize(book:, rank: nil, index: nil, ranking_configuration: nil)
    @book = book
    @rank = rank
    @index = index
    @ranking_configuration = ranking_configuration
  end

  private

  attr_reader :book, :rank, :index, :ranking_configuration

  # Under /rc/<id> the card keeps the viewer inside that configuration, so the
  # book page shows its rank there and a custom ranking keeps its banner. The
  # primary stays on the canonical, prefix-free URL (same rule as
  # Books::FilterPath#prefix).
  def book_link_path
    if ranking_configuration.nil? || ranking_configuration.primary?
      book_path(book.slug)
    else
      book_path(book.slug, ranking_configuration_id: ranking_configuration.id)
    end
  end

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
