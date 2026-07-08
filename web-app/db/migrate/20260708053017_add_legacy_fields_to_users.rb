class AddLegacyFieldsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :external_provider_uid, :string
    add_column :users, :legacy_migrated, :boolean
    add_column :users, :legacy_v1_data, :text
    add_index :users, [:external_provider, :external_provider_uid], name: "index_users_on_external_provider_and_uid"
  end
end
