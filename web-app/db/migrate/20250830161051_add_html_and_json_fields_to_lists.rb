class AddHtmlAndJsonFieldsToLists < ActiveRecord::Migration[8.0]
  def change
    add_column :lists, :simplified_html, :text
    add_column :lists, :items_json, :jsonb
  end
end
