class AddReimportDestinationIndexesToBooksRepairVerdicts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # MixedBooks.headed_to? asks "does any reimport_row end at this book, or any reimport_match name it" once per
  # mixed book and again under each book's lock. Without these it scans every verdict. kind 7 = reimport_match,
  # 8 = reimport_row (Books::RepairVerdict.kind).
  def change
    add_index :books_repair_verdicts, "((payload->>'to_book_id'))", where: "kind = 8",
      name: "index_books_repair_verdicts_on_reimport_row_destination", algorithm: :concurrently, if_not_exists: true
    add_index :books_repair_verdicts, "((payload->>'book_id'))", where: "kind = 7",
      name: "index_books_repair_verdicts_on_reimport_match_book", algorithm: :concurrently, if_not_exists: true
  end
end
