class CreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users do |t|
      t.string :auth_uid
      t.jsonb :auth_data
      t.string :email
      t.string :display_name
      t.string :name
      t.string :photo_url
      t.string :original_signup_domain
      t.integer :role, default: 0, null: false
      t.integer :external_provider
      t.boolean :email_verified, default: false, null: false
      t.datetime :last_sign_in_at
      t.integer :sign_in_count
      t.text :provider_data
      t.string :stripe_customer_id

      t.timestamps
    end

    add_index :users, :auth_uid
    add_index :users, :external_provider
    add_index :users, :stripe_customer_id
  end
end
