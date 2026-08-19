module Books
  # Settings -> canonical path. The ONLY place the canon's URL shape lives,
  # mirroring Books::FilterPath.
  #
  # The defaults collapse to the bare path so /global-canon never acquires a
  # spelled-out twin, and the controller uses that to 301 away from one.
  class GlobalCanonPath
    BASE = "/global-canon".freeze

    def self.call(settings)
      return BASE if settings.default?

      path = "#{BASE}/total_books/#{settings.total_books}" \
        "/nonfiction/#{settings.nonfiction_percentage}" \
        "/max_per_country/#{settings.max_books_per_country}"
      return path if settings.excluded_genres.empty?

      # Sorted so `poetry,fantasy` and `fantasy,poetry` cannot both exist as
      # separate cache entries and separate crawlable URLs.
      "#{path}/excluding/#{settings.excluded_genres.map(&:slug).sort.join(",")}"
    end
  end
end
