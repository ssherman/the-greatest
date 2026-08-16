namespace :data_migration do
  desc "Migrate legacy languages (fresh ids + legacy_id_maps)"
  task languages: :environment do
    pp Services::BooksMigration::LanguageMigrator.call
  end

  desc "Migrate legacy users into the global users table (preserves ids)"
  task users: :environment do
    pp Services::BooksMigration::UserMigrator.call
  end

  desc "Migrate legacy authors into books_authors (preserves ids)"
  task authors: :environment do
    pp Services::BooksMigration::AuthorMigrator.call
  end

  desc "Migrate legacy books into books_books (preserves ids; remaps language)"
  task books: :environment do
    pp Services::BooksMigration::BookMigrator.call
  end

  desc "Migrate legacy book_authors into books_book_authors"
  task book_authors: :environment do
    pp Services::BooksMigration::BookAuthorMigrator.call
  end

  desc "Migrate legacy editions into books_editions (fresh ids + map; sets default_edition_id)"
  task editions: :environment do
    pp Services::BooksMigration::EditionMigrator.call
  end

  desc "Migrate legacy identifiers (goodreads + openlibrary + ISBN family) into identifiers"
  task identifiers: :environment do
    pp Services::BooksMigration::BookIdentifierMigrator.call
    pp Services::BooksMigration::BookWorkIdentifierMigrator.call
    pp Services::BooksMigration::AuthorIdentifierMigrator.call
    pp Services::BooksMigration::EditionIdentifierMigrator.call
    pp Services::BooksMigration::EditionIsbnIdentifierMigrator.call
  end

  desc "Migrate legacy categories into Books::Category (fresh ids + map; preserves slug + parent)"
  task categories: :environment do
    pp Services::BooksMigration::CategoryMigrator.call
  end

  desc "Migrate legacy book_categories into category_items (bulk upsert; recomputes item_count)"
  task category_items: :environment do
    pp Services::BooksMigration::CategoryItemMigrator.call
  end

  desc "Migrate legacy countries into books_countries (preserves ids + slugs)"
  task countries: :environment do
    pp Services::BooksMigration::CountryMigrator.call
  end

  desc "Migrate legacy book_countries into books_book_countries (bulk upsert; recomputes book_count)"
  task book_countries: :environment do
    pp Services::BooksMigration::BookCountryMigrator.call
  end

  desc "Backfill book_length, page_range, and word_count onto migrated books"
  task book_attributes: :environment do
    pp Services::BooksMigration::BookAttributesMigrator.call
  end

  desc "Backfill category links for legacy book_type (recomputes item_count)"
  task book_type_categories: :environment do
    pp Services::BooksMigration::BookTypeCategoryMigrator.call
  end

  desc "Migrate legacy saved_searches into Books::SavedSearch (preserves ids; remaps categories)"
  task saved_searches: :environment do
    pp Services::BooksMigration::SavedSearchMigrator.call
  end

  desc "Migrate legacy links into external_links (Books::Book parent; source inferred from host)"
  task external_links: :environment do
    pp Services::BooksMigration::ExternalLinkMigrator.call
  end

  desc "Migrate legacy lists into Books::List (preserve id; status symbol-remap)"
  task lists: :environment do
    pp Services::BooksMigration::ListMigrator.call
  end

  desc "Migrate legacy list_items into list_items (listable = Books::Book; fresh id)"
  task list_items: :environment do
    pp Services::BooksMigration::ListItemMigrator.call
  end

  desc "Migrate active legacy ranking_configurations into Books::RankingConfiguration (fresh ids + map)"
  task ranking_configurations: :environment do
    pp Services::BooksMigration::RankingConfigurationMigrator.call
  end

  desc "Migrate legacy ranked_lists (active RCs only) into ranked_lists (bulk upsert; natural key)"
  task ranked_lists: :environment do
    pp Services::BooksMigration::RankedListMigrator.call
  end

  desc "Migrate legacy list_cons into penalties + penalty_applications (active RCs; reuse Global seeds)"
  task penalties: :environment do
    pp Services::BooksMigration::PenaltyMigrator.call
    pp Services::BooksMigration::PenaltyApplicationMigrator.call
  end

  desc "Migrate legacy list_con_lists into list_penalties (static penalties only)"
  task list_penalties: :environment do
    pp Services::BooksMigration::ListPenaltyMigrator.call
  end

  desc "Migrate legacy user_lists into Books::UserList (preserve id; list_type + view_mode symbol-remap)"
  task user_lists: :environment do
    pp Services::BooksMigration::UserListMigrator.call
  end

  desc "Migrate legacy user_list_books into user_list_items (listable = Books::Book; renumbers positions 1..N)"
  task user_list_items: :environment do
    pp Services::BooksMigration::UserListItemMigrator.call
  end

  desc "Enqueue cover-image import jobs for legacy Book primary_images (reads old R2 via S3 API; needs LEGACY_R2_* env)"
  task book_images: :environment do
    pp Services::BooksMigration::BookImageMigrator.call
  end

  desc "Backfill Description rows from the in-app games/music description columns (reads the current DB, no legacy connection)"
  task description_columns: :environment do
    pp Services::DescriptionColumnBackfill.call
  end

  desc "Backfill Description rows from the legacy books description columns (all three; insert_all, skip-on-conflict)"
  task book_descriptions: :environment do
    result = Services::BooksMigration::BookDescriptionMigrator.call
    pp result
    abort "book_descriptions failed: #{result[:error]}" unless result[:success]
  end

  desc "Backfill Description rows from the legacy authors description columns (ai_description + description)"
  task author_descriptions: :environment do
    result = Services::BooksMigration::AuthorDescriptionMigrator.call
    pp result
    abort "author_descriptions failed: #{result[:error]}" unless result[:success]
  end

  desc "Give a :manual Description row to in-app books/authors the legacy backfill did not cover (run LAST)"
  task description_safety_net: :environment do
    result = Services::BooksDescriptionSafetyNet.call
    pp result
    abort "description_safety_net failed: #{result.errors.inspect}" unless result.success?
  end

  # Order is load-bearing: the safety net's "no row" is defined relative to the two legacy
  # migrators having run. Run it first and it stamps :manual onto legacy-sourced text.
  desc "Run the books/authors description backfill in order (both legacy migrators, then the safety net)"
  task descriptions: [:book_descriptions, :author_descriptions, :description_safety_net]

  desc "Migrate legacy reviews into reviews (preserves ids; then rebuilds review_summaries)"
  task reviews: :environment do
    # Untargeted ON CONFLICT DO NOTHING makes every conflict silent, so print the
    # arithmetic: on a cold load, inserted MUST equal legacy_distinct_pairs. A shortfall
    # means rows were skipped -- most likely id collisions with reviews real users wrote
    # before this ran.
    expected = LegacyBooks::Record.connection.select_value(
      "select count(*) from (select distinct user_id, book_id from reviews) t"
    ).to_i
    pre_existing = Review.count

    result = Services::BooksMigration::ReviewMigrator.call
    pp result
    abort "reviews migration failed: #{result[:error]}" unless result[:success]

    pp({
      legacy_distinct_pairs: expected,
      inserted: result[:data][:count],
      pre_existing: pre_existing,
      cold_load_matches: pre_existing.zero? && result[:data][:count] == expected
    })

    # insert_all bypassed every after_commit, so the summaries are stale by definition.
    pp({review_summaries: Services::Reviews::SummaryRecalculator.backfill_all!})
  end

  desc "Import legacy users.paid early supporters as source: :legacy memberships"
  task memberships: :environment do
    # Print the arithmetic rather than trusting the count: upsert_row skips
    # silently for a user missing from the new users table, and a silent skip in
    # a billing migration is exactly the thing worth surfacing.
    legacy_paid = LegacyBooks::User.where(paid: true).count

    result = Services::BooksMigration::MembershipMigrator.call
    pp result
    abort "memberships migration failed: #{result[:error]}" unless result[:success]

    granted = Membership.source_legacy.count
    pp({
      legacy_paid_users: legacy_paid,
      legacy_memberships_now: granted,
      unaccounted_for: legacy_paid - granted
    })
  end

  desc "Run all Phase-1 migrators in dependency order"
  task all: [:languages, :users, :authors, :books, :book_authors, :editions, :identifiers,
    :categories, :category_items, :book_attributes, :book_type_categories, :countries,
    :book_countries, :external_links, :lists, :list_items, :ranking_configurations,
    :ranked_lists, :penalties, :list_penalties, :user_lists, :user_list_items,
    :saved_searches, :reviews]
end
