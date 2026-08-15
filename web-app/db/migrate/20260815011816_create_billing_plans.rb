class CreateBillingPlans < ActiveRecord::Migration[8.1]
  def change
    create_table :billing_plans do |t|
      t.integer :kind, null: false
      t.string :key, null: false
      t.string :name, null: false
      t.integer :interval
      t.integer :amount_cents
      t.string :currency, null: false, default: "usd"
      t.string :stripe_price_id, null: false
      t.string :stripe_lookup_key
      t.boolean :active, null: false, default: true
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :billing_plans, :key, unique: true
    add_index :billing_plans, :stripe_price_id, unique: true
  end
end
