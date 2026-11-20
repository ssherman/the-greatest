# frozen_string_literal: true

# One full-width card of covers. :favorites is a primary card (an owner with
# none gets a prompt). :recently_read and :top_rated are secondary: nothing at
# all when empty. :top_rated takes `rated` (Library::RatedBook) instead of a
# shelf and prints each book's rating under its cover.
class Books::Profiles::ShelfCardComponent < ViewComponent::Base
  KINDS = {
    favorites: {
      title: "Favorites",
      empty: "Your favorite books will show up here.",
      action: "Find books to favorite"
    },
    recently_read: {title: "Recently read"},
    top_rated: {title: "Highest rated"}
  }.freeze

  def initialize(kind:, audience:, shelf: nil, rated: nil, data: nil)
    @kind = kind
    @shelf = shelf
    @rated = rated || []
    @audience = audience
    @data = data
  end

  def render?
    entries.any? || prompt?
  end

  private

  attr_reader :kind, :shelf, :rated, :audience, :data

  def owner? = audience == :owner

  def copy = KINDS.fetch(kind)

  def title = copy.fetch(:title)

  # [book, rating-or-nil] pairs, whichever source this kind draws on.
  def entries
    @entries ||= (kind == :top_rated) ? rated.map { |r| [r.book, r.rating] } : (shelf&.books || []).map { |book| [book, nil] }
  end

  def primary? = kind == :favorites

  def prompt? = owner? && primary? && entries.empty?

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
