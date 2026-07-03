class ReserveListsIdRange < ActiveRecord::Migration[8.1]
  # Reserves the low PK range on the shared `lists` table for the future books
  # import (preserves original book-list IDs so legacy /lists/:id URLs keep
  # working). Re-runs Services::BooksMigration::IdRangeReservationService, which
  # now also relocates existing new-app `lists` rows above the `lists` ceiling,
  # remaps every column referencing lists.id (incl. the polymorphic
  # ai_chats.parent), and bumps the lists sequence. `users`/`user_lists` were
  # reserved by an earlier migration and are a no-op here.
  # See docs/superpowers/plans/2026-07-03-lists-id-range-reservation.md and
  # docs/specs/completed/books-migration-01-id-range-reservation.md.
  #
  # Idempotent — safe to re-run. db/schema.rb does NOT capture sequence RESTART
  # values, so db:schema:load starts sequences at 1 again; acceptable because the
  # reservation only needs to hold where the books import runs (prod + dev).
  def up
    result = Services::BooksMigration::IdRangeReservationService.call
    raise "Lists ID range reservation failed: #{result[:error]}" unless result[:success]
  end

  def down
    # Intentionally irreversible: relocating rows and restarting sequences cannot
    # be cleanly undone. Restore from a snapshot if reversal is ever needed.
  end
end
