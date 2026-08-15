class CreateMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :memberships do |t|
      # Nullable on purpose: with one shared Stripe account and a live legacy
      # app, an unmappable customer will eventually appear. Storing it
      # unattached beats dropping it silently.
      t.references :user, null: true, foreign_key: true
      t.integer :source, null: false, default: 0
      t.integer :status, null: false
      t.integer :interval
      t.string :stripe_subscription_id
      t.string :stripe_customer_id
      # nil means "never expires" — used by comped memberships.
      t.datetime :current_period_end
      t.datetime :canceled_at
      t.boolean :cancel_at_period_end, null: false, default: false
      t.string :origin_domain
      t.datetime :welcome_email_sent_at
      t.datetime :ended_email_sent_at
      t.datetime :stripe_synced_at
      t.text :note
      t.references :granted_by, null: true, foreign_key: {to_table: :users}

      t.timestamps
    end

    # Partial: comped and legacy rows have no subscription id, and several NULLs
    # must be allowed to coexist.
    add_index :memberships, :stripe_subscription_id,
      unique: true, where: "stripe_subscription_id IS NOT NULL"
    add_index :memberships, [:user_id, :status]
    add_index :memberships, :stripe_customer_id
  end
end
