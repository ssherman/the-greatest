class AddReimportSweepIndexesToBooksRepairVerdicts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Apply::Leftovers runs after every settled row of a re-import and must narrow to one reader's rows touching one book
  # without scanning every verdict. kind 8 = reimport_row, 7 = reimport_match, 1 = merge_books
  # (Books::RepairVerdict.kind). The to_book_id and book_id indexes already exist (20261103234851).
  def change
    add_index :books_repair_verdicts, "((payload->>'user_id'))", where: "kind = 8",
      name: "index_books_repair_verdicts_on_reimport_row_user", algorithm: :concurrently, if_not_exists: true
    add_index :books_repair_verdicts, "((payload->>'from_book_id'))", where: "kind = 8",
      name: "index_books_repair_verdicts_on_reimport_row_source", algorithm: :concurrently, if_not_exists: true
    add_index :books_repair_verdicts, "((payload->>'created_book_id'))", where: "kind = 7",
      name: "index_books_repair_verdicts_on_reimport_match_created_book", algorithm: :concurrently, if_not_exists: true
    add_index :books_repair_verdicts, "((payload->>'target_id'))", where: "kind = 1",
      name: "index_books_repair_verdicts_on_merge_target", algorithm: :concurrently, if_not_exists: true
  end
end
