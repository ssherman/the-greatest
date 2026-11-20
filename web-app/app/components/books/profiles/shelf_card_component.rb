# frozen_string_literal: true

# One card of covers. :favorites is a primary card (an owner with none gets a
# prompt); :recently_read is the read shelf plus, in the same card, the
# highest-rated books, and both are secondary (nothing when empty).
class Books::Profiles::ShelfCardComponent < ViewComponent::Base
  KINDS = {
    favorites: {
      title: "Favorites",
      empty: "Your favorite books will show up here.",
      action: "Find books to favorite"
    },
    recently_read: {title: "Recently read"}
  }.freeze

  def initialize(kind:, shelf:, audience:, top_rated: nil, data: nil)
    @kind = kind
    @shelf = shelf
    @audience = audience
    @top_rated = top_rated || []
    @data = data
  end

  def render?
    books.any? || top_rated.any? || prompt?
  end

  private

  attr_reader :kind, :shelf, :audience, :top_rated, :data

  def owner? = audience == :owner

  def copy = KINDS.fetch(kind)

  def title = copy.fetch(:title)

  def books = shelf&.books || []

  def primary? = kind == :favorites

  def prompt? = owner? && primary? && books.empty?

  def see_all_path
    list = shelf&.list
    return unless list

    if owner?
      helpers.my_list_path(list)
    elsif data&.linkable?(list)
      helpers.user_list_path(list)
    end
  end
end
