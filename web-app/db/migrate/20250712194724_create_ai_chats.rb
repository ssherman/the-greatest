class CreateAiChats < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_chats do |t|
      t.integer :chat_type, default: 0, null: false
      t.string :model, null: false
      t.integer :provider, default: 0, null: false
      t.decimal :temperature, precision: 3, scale: 2, default: 0.2, null: false
      t.boolean :json_mode, default: false, null: false
      t.jsonb :response_schema
      t.jsonb :messages
      t.jsonb :raw_responses
      t.references :parent, polymorphic: true, null: true
      t.references :user, null: true, foreign_key: true

      t.timestamps
    end
  end
end
