# frozen_string_literal: true

# Title, by-line and cover for whichever listable a list item points at. Shared
# by the list page and the Edit page so the two never disagree about how an
# item is named. The including component must define `listable`.
module UserLists::ListableDisplay
  private

  def by_line
    if listable.is_a?(Books::Book)
      listable.book_authors.map { |book_author| book_author.author.name }.join(", ")
    elsif listable.respond_to?(:artists)
      listable.artists.map(&:name).join(", ")
    elsif listable.is_a?(Games::Game)
      listable.game_companies.select(&:developer?).map { |gc| gc.company.name }.join(", ")
    else
      ""
    end
  end

  def title
    listable.try(:title) || listable.try(:name)
  end

  # The attached primary image, or nil (songs have none).
  def cover
    image = listable.try(:primary_image)
    image if image&.file&.attached?
  end
end
