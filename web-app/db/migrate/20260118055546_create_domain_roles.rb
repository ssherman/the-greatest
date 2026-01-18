class CreateDomainRoles < ActiveRecord::Migration[8.1]
  def change
    create_table :domain_roles do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :domain, null: false
      t.integer :permission_level, null: false, default: 0

      t.timestamps
    end

    add_index :domain_roles, [:user_id, :domain], unique: true
    add_index :domain_roles, :domain
    add_index :domain_roles, :permission_level
  end
end
