# frozen_string_literal: true

class Books::Profiles::StatTilesComponent < ViewComponent::Base
  Tile = Struct.new(:key, :label, :value, :detail, :link, keyword_init: true)

  # read_list is where "Add finish dates" points; the stats do not know it.
  def initialize(stats:, audience:, read_list: nil)
    @stats = stats
    @audience = audience
    @read_list = read_list
  end

  def render?
    !stats.nil? && tiles.any?
  end

  private

  attr_reader :stats, :audience, :read_list

  def owner? = audience == :owner

  # An owner sees every tile, with a dash where there is nothing to count; a
  # visitor sees only the tiles that have a number, so the row closes up.
  def tiles
    @tiles ||= all_tiles.select { |tile| owner? || !tile.value.nil? }
  end

  def all_tiles
    [
      Tile.new(key: "books-read", label: "Books read", value: stats.books_read),
      Tile.new(key: "read-last-12-months", label: "Read in the last 12 months",
        value: stats.read_last_12_months, link: finish_dates_link(stats.read_last_12_months)),
      Tile.new(key: "average-rating", label: "Average rating",
        value: stats.average_rating && helpers.number_with_precision(stats.average_rating, precision: 1),
        detail: stats.ratings_count && "#{helpers.number_with_delimiter(stats.ratings_count)} ratings"),
      Tile.new(key: "reviews", label: "Reviews", value: stats.reviews_count)
    ]
  end

  def finish_dates_link(value)
    return unless owner? && value.nil? && read_list

    helpers.my_list_path(read_list)
  end

  def display(value)
    return "—" if value.nil?

    value.is_a?(Integer) ? helpers.number_with_delimiter(value) : value
  end
end
