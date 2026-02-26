class RemoveFormattedTextFromLists < ActiveRecord::Migration[8.1]
  def change
    remove_column :lists, :formatted_text, :text
  end
end
