class AddSecondChanceToBooksVerifications < ActiveRecord::Migration[8.1]
  def change
    add_column :books_verifications, :second_chance_at, :datetime
    add_column :books_verifications, :prior_outcome, :integer
    add_column :books_verifications, :prior_keys, :string, array: true, default: [], null: false
  end
end
