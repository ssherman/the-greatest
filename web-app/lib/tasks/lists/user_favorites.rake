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
end
