class ReserveBooksIdRanges < ActiveRecord::Migration[8.1]
  # Reserves the low PK range on `users`/`user_lists` for the future books
  # import (preserves original book IDs with zero collisions). Relocates the
  # handful of existing new-app rows up by ID_CEILING and bumps both sequences.
  # See docs/specs/completed/books-migration-01-id-range-reservation.md.
  #
  # Idempotent — safe to re-run. Note: db/schema.rb does NOT capture sequence
  # RESTART values, so db:schema:load (CI, fresh dev DBs) starts sequences at 1
  # again. That is acceptable — the reservation only needs to hold in production
  # and any environment that will receive the books import.
  def up
    result = Services::BooksMigration::IdRangeReservationService.call
    raise "Books ID range reservation failed: #{result[:error]}" unless result[:success]
  end

  def down
    # Intentionally irreversible: relocating rows and restarting sequences cannot
    # be cleanly undone. Restore from a snapshot if reversal is ever needed.
  end
end
