class AddBlockedFetchesAndSweepsToBooksBookSubmissions < ActiveRecord::Migration[8.1]
  # blocked_fetches: Goodreads fetches for this submission that came back
  # blocked (one reader-supplied link must not hold the gate shut). sweeps:
  # times the stuck-row sweep queued it again (a submission that kills its
  # worker must not run forever).
  def change
    add_column :books_book_submissions, :blocked_fetches, :integer, default: 0, null: false
    add_column :books_book_submissions, :sweeps, :integer, default: 0, null: false
  end
end
