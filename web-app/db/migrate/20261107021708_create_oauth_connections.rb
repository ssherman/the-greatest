class CreateOauthConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_connections do |t|
      t.references :user, null: false, foreign_key: true
      t.references :oauth_application, null: false, foreign_key: true
      t.string :resource, null: false
      t.string :scopes, array: true, default: [], null: false
      t.datetime :approved_at, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :oauth_connections, [:user_id, :oauth_application_id, :resource],
      unique: true, name: "index_oauth_connections_on_user_app_resource"
  end
end
