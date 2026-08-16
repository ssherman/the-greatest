class AddOneGrantPerUserIndexToMemberships < ActiveRecord::Migration[8.1]
  def change
    # source <> 0 is "not :stripe". A user may hold any number of Stripe
    # subscriptions -- that is Stripe's business -- but at most one legacy
    # early-supporter grant and at most one comp. This is what makes both
    # MembershipMigrator and the admin comp form idempotent structurally
    # rather than by convention.
    #
    # user_id IS NOT NULL is required, not decorative: an unattached row is a
    # customer we could not map, and several of those must be able to coexist.
    add_index :memberships, [:user_id, :source],
      unique: true,
      where: "source <> 0 AND user_id IS NOT NULL",
      name: "index_memberships_one_grant_per_user_per_source"
  end
end
