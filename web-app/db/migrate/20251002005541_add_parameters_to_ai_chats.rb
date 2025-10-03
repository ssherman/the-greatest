class AddParametersToAiChats < ActiveRecord::Migration[8.0]
  def change
    add_column :ai_chats, :parameters, :jsonb
  end
end
