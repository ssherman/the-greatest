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

  # The legacy site kept three lists built from user favorites: a top 100, a
  # 6,933-item "honorable mention" holding everything from 101 down, and an older
  # stale artifact. The honorable mention is retired outright -- at weight 0 it
  # contributed nothing, and all 2,854 books it uniquely carried score at the
  # engine's floor of 1.00.
  #
  # The top 100 is kept and adopted: it already owns its public URL, its
  # RankedList row, its weight and its penalties. Renaming it in place preserves
  # all of that.
  #
  # Books data lives in development only, so this finds lists by name and no-ops
  # when they are absent -- safe to run anywhere, safe to re-run.
  desc "Adopt the legacy books users' list and delete the retired ones (one-time, safe to re-run)"
  task adopt_legacy_books_list: :environment do
    keep = ::Books::List.find_by(name: "Our Users' Top 100 Favorite Books of All Time")

    if keep
      keep.update!(
        name: ::Books::UserList.generated_list_name,
        description: ::Books::UserList.generated_list_description,
        auto_generated_kind: :user_favorites
      )
      puts "Adopted list #{keep.id} as the generated books users' list."
    else
      puts "No legacy top-100 list found; nothing to adopt."
    end

    [
      "Our Users' Honorable Mention Favorite Books of All Time",
      "Our Users' Favorite Books of All Time"
    ].each do |name|
      # Skip the list we just renamed into this slot.
      doomed = ::Books::List.where(name: name).where.not(id: keep&.id).to_a
      doomed.each do |list|
        items = list.list_items.count
        # RankedList is destroyed by the association added in Task 2; counted here
        # so the output says what actually went.
        ranked = list.ranked_lists.count
        list.destroy!
        puts "Deleted list #{list.id} \"#{name}\" (#{items} items, #{ranked} ranked_list row(s))."
      end
      puts "No list named \"#{name}\"; nothing to delete." if doomed.empty?
    end
  end
end
