# frozen_string_literal: true

namespace :user_favorites_lists do
  desc "Rebuild the generated users' favorites list for every domain, or one (e.g. Books::UserList)"
  task :generate, [:user_list_class] => :environment do |_task, args|
    GenerateUserFavoritesListsJob.new.perform(args[:user_list_class])
    puts "Done."
  end

  desc "Backfill user_lists.manually_ordered from item insertion order (one-time, safe to re-run)"
  task backfill_manually_ordered: :environment do
    count = Services::UserLists::BackfillManuallyOrdered.call
    puts "Flagged #{count} user list(s) as manually ordered."
  end

  # Everything the generated favorites lists need after a books import, in the
  # one order that works. Idempotent, and safe in any environment: every step
  # either no-ops or converges.
  #
  # This replaces the old `adopt_legacy_books_list`, which renamed the legacy
  # top-100 in place and flagged it as the generated list. Adoption failed twice
  # in practice -- it hit the (type, auto_generated_kind) unique index whenever a
  # generated list already existed, and its own guard was single-use, because the
  # first run destroyed the pre-rename name the guard looked itself up by. There
  # is nothing left worth adopting: the generator rebuilds the list from live
  # user_lists, and maintains its RankedList and penalty as invariants (see
  # Services::Lists::GenerateUserFavorites#ensure_wiring).
  #
  # THIS TASK ACTIVATES THE LIST; THE NIGHTLY JOB DOES NOT. The generator never
  # touches `status` after create, because status is the admin's way of taking
  # the list out of the rankings and that has to survive the nightly run.
  # Running this task is an operator saying "make this correct now", so step 4
  # overrides a deactivation on purpose.
  desc "Rebuild the generated users' favorites lists end to end, ACTIVATING each one (safe to re-run, any environment)"
  task rebuild: :environment do
    # 1. Re-imported user_lists come back with manually_ordered false, and a
    #    ballot that is not manually ordered scores flat -- so this has to
    #    happen before the tally reads them, not after.
    count = Services::UserLists::BackfillManuallyOrdered.call
    puts "Flagged #{count} user list(s) as manually ordered."

    # 2. Retire any legacy list still standing. ListMigrator no longer imports
    #    these, but a database loaded before that change still holds them --
    #    production is in exactly that state.
    #
    #    Scoped by `auto_generated_kind: nil`, never by excluding an id. One of
    #    the three names IS ::Books::UserList.generated_list_name, so a name
    #    match alone would take the generated list with it; excluding a
    #    remembered id was the bug in the task this replaces.
    Services::BooksMigration::ListMigrator::SUPERSEDED_LIST_NAMES.each do |name|
      doomed = ::Books::List.where(name: name, auto_generated_kind: nil).to_a

      if doomed.empty?
        puts "No retired list named #{name.inspect}; nothing to delete."
        next
      end

      doomed.each do |list|
        items = list.list_items.count
        ranked = list.ranked_lists.count
        list.destroy!
        puts "Deleted list #{list.id} #{name.inspect} (#{items} items, #{ranked} ranked_list row(s))."
      end
    end

    # 3. Rebuild every domain's generated list from live favorites, creating it
    #    if it does not exist yet and ensuring its RankedList and penalty either
    #    way. This is what repairs a list created before the wiring existed.
    GenerateUserFavoritesListsJob.new.perform

    # 4. Force each generated list active. The generator deliberately leaves
    #    `status` alone -- an admin who deactivates the list must not have that
    #    undone every night -- but running THIS task is an explicit "make it
    #    correct now", so here the override is the point.
    ::UserList.generating_subclasses.each do |klass|
      list = klass.generated_list_class.find_by(auto_generated_kind: :user_favorites)
      next if list.nil? || list.active?

      was = list.status
      list.update!(status: :active)
      puts "Activated list #{list.id} #{list.name.inspect} (was #{was})."
    end

    puts "Done."
  end
end
