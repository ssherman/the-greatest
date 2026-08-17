module LegacyBooks
  # Read for verification only. The legacy subscriptions table is deliberately
  # NOT migrated -- it was written by the handler this subsystem replaces and is
  # the least trustworthy copy of the data. Stripe is the source of truth, and
  # billing:reconcile_all already rebuilt every membership from it. This model
  # exists so verify_migration can ask "is every subscription legacy knew about
  # accounted for?" without importing any of it.
  class Subscription < Record
    self.table_name = "subscriptions"
  end
end
