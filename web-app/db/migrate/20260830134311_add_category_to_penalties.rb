class AddCategoryToPenalties < ActiveRecord::Migration[8.1]
  def change
    # Nullable on purpose. A penalty created in admin without a category still
    # renders on the public rankings page under an "Other" heading rather than
    # silently disappearing from it -- the failure mode has to be visible.
    add_column :penalties, :category, :integer

    add_index :penalties, :category
  end
end
