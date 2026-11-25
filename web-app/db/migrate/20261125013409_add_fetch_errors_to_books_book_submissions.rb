class AddFetchErrorsToBooksBookSubmissions < ActiveRecord::Migration[8.1]
  # Errors raised by the Goodreads fetch job after it was granted a gate turn,
  # cumulative for the submission (the third ends it as failed).
  def change
    add_column :books_book_submissions, :fetch_errors, :integer, default: 0, null: false
  end
end
