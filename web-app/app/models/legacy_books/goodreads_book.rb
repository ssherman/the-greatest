module LegacyBooks
  # The legacy app's Goodreads cache. Only its scraped rows are read, by the
  # page-cache seed (Goodreads import spec §6, "Legacy seed").
  class GoodreadsBook < Record
    self.table_name = "goodreads_books"

    # Rows a Goodreads lookup wrote: a page lookup sets last_looked_up_at
    # (and last_refreshed_at), a search result only last_refreshed_at. Rows
    # built from export rows carry neither.
    scope :scraped, -> { where.not(last_looked_up_at: nil).or(where.not(last_refreshed_at: nil)) }
  end
end
