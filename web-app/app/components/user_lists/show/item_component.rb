# frozen_string_literal: true

class UserLists::Show::ItemComponent < ViewComponent::Base
  include Music::DefaultHelper
  include Games::DefaultHelper

  # Listables that have a dedicated card component (rendered as a <div> in
  # default/grid views). Everything else (songs, movies) renders as a <tr>
  # table row.
  CARD_LISTABLES = %w[Music::Album Games::Game Books::Book].freeze

  DEFAULT_GRID_CONTAINER_CLASS =
    "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6"

  def initialize(item:, view_mode:, position:, index: nil)
    @item = item
    @view_mode = view_mode.to_s
    @position = position
    @index = index
  end

  def self.card_capable?(listable_class)
    CARD_LISTABLES.include?(listable_class.to_s)
  end

  # Whether items of this listable/view_mode render as <tr> rows (needing a
  # <table>/<thead> wrapper) instead of card <div>s. table_view is tabular for
  # everything; cardless listables (songs, movies) are always tabular. The show
  # view calls this once (lists are homogeneous) to pick the wrapper.
  def self.table_layout?(listable_class:, view_mode:)
    view_mode.to_s == "table_view" || !card_capable?(listable_class)
  end

  # Books covers are 2:3 and tile far denser than square album art, so books get
  # their own grid shape — the same one the homepage and /lists/:id use. Every
  # other listable keeps the four-column grid, which already matches the music
  # and games ranked grids. Called once per page: lists are homogeneous.
  def self.grid_container_class(listable_class)
    if listable_class.to_s == "Books::Book"
      Books::CardComponent::GRID_CONTAINER_CLASS
    else
      DEFAULT_GRID_CONTAINER_CLASS
    end
  end

  private

  attr_reader :item, :view_mode, :position, :index

  def listable
    item.listable
  end

  def render_as_row?
    self.class.table_layout?(listable_class: listable.class.name, view_mode: view_mode)
  end

  # The dedicated card for card-capable listables (grid view).
  def listable_card
    case listable
    when Music::Album then Music::Albums::CardComponent.new(album: listable)
    when Games::Game then Games::CardComponent.new(game: listable)
    when Books::Book then Books::CardComponent.new(book: listable, rank: position, index: index)
    end
  end

  # --- List ("default") view row, for card-capable listables only ---

  # Title rendered as a link to the listable's show page (domain helper).
  def title_link
    case listable
    when Music::Album then link_to_album(listable, nil, class: "hover:text-primary")
    when Games::Game then link_to_game(listable, nil, class: "hover:text-primary")
    when Books::Book then link_to(listable.title, book_path(listable.slug), class: "hover:text-primary")
    else title
    end
  end

  def description
    listable.try(:primary_description)&.content
  end

  def cover_image
    listable.primary_image if listable.respond_to?(:primary_image)
  end

  def cover_aspect_class
    case listable
    when Books::Book then "aspect-[2/3]"
    when Games::Game then "aspect-[3/4]"
    else "aspect-square"
    end
  end

  def completed_on_badge?
    completed_on_column? && item.completed_on.present?
  end

  # Songs get their richer list-item row outside table_view; everything else in
  # a row context uses the shared generic row below.
  def rich_song_row?
    view_mode != "table_view" && listable.is_a?(Music::Song)
  end

  # Column presence is list-level (per the completed_on capability), independent
  # of whether a given item has a date.
  def completed_on_column?
    item.user_list.completed_on_enabled?
  end

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

  def year
    listable.is_a?(Books::Book) ? listable.first_published_year : listable.try(:release_year)
  end
end
