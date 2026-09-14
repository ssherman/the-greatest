# frozen_string_literal: true

# Offset pagination for API collections: parses and validates `page` and
# `per_page`, and produces the `meta` and `links` members of a collection
# envelope. A page past the end is legal and empty -- what an iterating client
# expects -- which matches the empty-page behaviour Pagy gives the site.
#
# Not Pagy itself: the site's helper reads the page from the request and 404s
# past the end; the API validates its own parameters and answers 400 with a
# problem body naming the offender.
module Api
  class Page
    class InvalidParameter < StandardError; end

    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE = 100

    attr_reader :page, :per_page, :total_count

    def self.from_params(params, total_count:)
      new(
        page: integer(params[:page], name: "page", default: 1, min: 1),
        per_page: integer(params[:per_page], name: "per_page", default: DEFAULT_PER_PAGE, min: 1, max: MAX_PER_PAGE),
        total_count: total_count
      )
    end

    def self.integer(raw, name:, default:, min:, max: nil)
      return default if raw.nil?

      value = Integer(raw.to_s, 10, exception: false)
      in_range = value && value >= min && (max.nil? || value <= max)
      return value if in_range

      range = max ? "between #{min} and #{max}" : "#{min} or greater"
      raise InvalidParameter, "#{name} must be an integer #{range}"
    end

    def initialize(page:, per_page:, total_count:)
      @page = page
      @per_page = per_page
      @total_count = total_count
    end

    def offset = (page - 1) * per_page

    def total_pages = [(total_count.to_f / per_page).ceil, 1].max

    def next_page = (page < total_pages) ? page + 1 : nil

    def prev_page = (page > 1) ? [page - 1, total_pages].min : nil

    def meta = {page: page, per_page: per_page, total_count: total_count, total_pages: total_pages}

    def links(base_url)
      {
        self: url(base_url, page),
        next: next_page && url(base_url, next_page),
        prev: prev_page && url(base_url, prev_page),
        first: url(base_url, 1),
        last: url(base_url, total_pages)
      }
    end

    private

    def url(base_url, number) = "#{base_url}?page=#{number}&per_page=#{per_page}"
  end
end
