namespace :data_migration do
  desc "Migrate legacy languages (fresh ids + legacy_id_maps)"
  task languages: :environment do
    pp Services::BooksMigration::LanguageMigrator.call
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

  desc "Run all Phase-1 migrators in dependency order"
  task all: [:languages, :authors, :books, :book_authors, :editions]
end
