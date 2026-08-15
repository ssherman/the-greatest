class CreateStripeEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :stripe_events do |t|
      t.string :stripe_event_id, null: false
      t.string :event_type, null: false
      # The FULL event, not just data.object. Legacy stored only the object and
      # lost the event type context and livemode along with it.
      t.jsonb :payload, null: false
      t.boolean :livemode, null: false
      t.string :api_version
      t.string :stripe_customer_id
      t.integer :status, null: false, default: 0
      t.datetime :stripe_created_at, null: false
      t.datetime :processed_at
      t.integer :attempts, null: false, default: 0
      t.text :error

      t.timestamps
    end

    # Unique, unlike legacy's plain index. This index IS the idempotency check:
    # a redelivered event fails the insert instead of being processed twice.
    add_index :stripe_events, :stripe_event_id, unique: true
    add_index :stripe_events, [:status, :created_at]
    add_index :stripe_events, :stripe_customer_id
  end
end
