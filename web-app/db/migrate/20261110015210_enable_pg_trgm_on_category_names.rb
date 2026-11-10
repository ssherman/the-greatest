class EnablePgTrgmOnCategoryNames < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pg_trgm"
    add_index :categories, "lower(name) gin_trgm_ops", using: :gin, name: "index_categories_on_lower_name_trgm"
  end
end
