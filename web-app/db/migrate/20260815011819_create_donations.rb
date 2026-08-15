class CreateDonations < ActiveRecord::Migration[8.1]
  def change
    create_table :donations do |t|
      # Nullable: donations may be made while signed out.
      t.references :user, null: true, foreign_key: true
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "usd"
      t.integer :status, null: false, default: 0
      t.string :stripe_payment_intent_id
      t.string :stripe_checkout_session_id
      t.string :email
      t.string :domain

      t.timestamps
    end

    add_index :donations, :stripe_payment_intent_id,
      unique: true, where: "stripe_payment_intent_id IS NOT NULL"
  end
end
