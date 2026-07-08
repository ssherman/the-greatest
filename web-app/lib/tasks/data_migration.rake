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

  desc "Run all Phase-1 migrators in dependency order"
  task all: [:languages, :users, :authors, :books, :book_authors, :editions, :identifiers, :categories, :category_items]
end
