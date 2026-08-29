class CreateContactMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :contact_messages do |t|
      t.references :user, null: true, foreign_key: true
      t.string :email, null: false
      t.text :message, null: false
      t.integer :domain, null: false
      t.integer :status, null: false, default: 0
      t.datetime :replied_at
      t.string :submitter_ip

      t.timestamps
    end

    # Backs the admin queue: "pending messages for this domain, newest first"
    # is every index page load.
    add_index :contact_messages, [:status, :created_at]
    add_index :contact_messages, [:domain, :created_at]
  end
end
