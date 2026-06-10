# frozen_string_literal: true

class UserLists::Show::ItemComponent < ViewComponent::Base
  include Music::DefaultHelper
  include Games::DefaultHelper

  # Listables that have a dedicated card component (rendered as a <div> in
  # default/grid views). Everything else (songs, movies, future books) renders
  # as a <tr> table row.
  CARD_LISTABLES = %w[Music::Album Games::Game].freeze

  def initialize(item:, view_mode:, position:)
    @item = item
    @view_mode = view_mode.to_s
    @position = position
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

  private

  attr_reader :item, :view_mode, :position

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
    end
  end

  # --- List ("default") view row, for card-capable listables only ---

  # Title rendered as a link to the listable's show page (domain helper).
  def title_link
    case listable
    when Music::Album then link_to_album(listable, nil, class: "hover:text-primary")
    when Games::Game then link_to_game(listable, nil, class: "hover:text-primary")
    else title
    end
  end

  def description
    listable.try(:description)
  end

  def cover_image
    listable.primary_image if listable.respond_to?(:primary_image)
  end

  # Album covers are square; game box art is portrait.
  def cover_aspect_class
    listable.is_a?(Games::Game) ? "aspect-[3/4]" : "aspect-square"
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
    if listable.respond_to?(:artists)
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
    listable.try(:release_year)
  end
end
