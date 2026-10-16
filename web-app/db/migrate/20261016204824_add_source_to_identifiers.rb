class AddSourceToIdentifiers < ActiveRecord::Migration[8.1]
  def change
    add_column :identifiers, :source, :integer
  end
end
