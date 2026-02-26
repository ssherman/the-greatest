class RenameHtmlColumnsOnLists < ActiveRecord::Migration[8.1]
  def change
    rename_column :lists, :raw_html, :raw_content
    rename_column :lists, :simplified_html, :simplified_content
  end
end
