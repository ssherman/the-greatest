class AddClaimsToBooksBookSubmissions < ActiveRecord::Migration[8.1]
  # How many times an agent has been handed this row. `attempts` cannot count
  # this: the lookup's retry schedule counts its own retries there, so a row
  # that retried twice would look half-abandoned the first time an agent saw it.
  def change
    add_column :books_book_submissions, :claims, :integer, default: 0, null: false
  end
end
