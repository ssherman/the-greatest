class ReserveBooksCatalogIdRanges < ActiveRecord::Migration[8.1]
  # Moves the books_books, books_authors, reviews and saved_searches id sequences up
  # to their Services::BooksMigration::RESERVED_CEILINGS, so rows this app creates
  # (Goodreads imports, member reviews) never take an id legacy will hand out before
  # the books cutover. Sequence only: no rows move, because every row in these tables
  # came from legacy. Idempotent, never moves a sequence backward, and never raises
  # on data -- a raising migration crash-loops the web container for all four sites.
  #
  # db/schema.rb does not capture sequence values, so a db:schema:load database starts
  # low again; the four migrators' finalize puts the floor back on their next run.
  # See docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md §3.
  def up
    Services::BooksMigration.reserve_sequence_floors!
  end

  def down
    # Nothing to undo: a higher sequence start is harmless.
  end
end
