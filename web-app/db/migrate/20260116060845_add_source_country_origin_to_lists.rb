class AddSourceCountryOriginToLists < ActiveRecord::Migration[8.1]
  def change
    add_column :lists, :source_country_origin, :string
  end
end
