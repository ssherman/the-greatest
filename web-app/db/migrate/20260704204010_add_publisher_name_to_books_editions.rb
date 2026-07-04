class AddPublisherNameToBooksEditions < ActiveRecord::Migration[8.1]
  def change
    add_column :books_editions, :publisher_name, :string
  end
end
