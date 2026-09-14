# Shared SQL capture for query-count assertions. Skips SCHEMA queries.
#
# Does NOT define assert_no_queries: Rails 8.1's
# ActiveRecord::Assertions::QueryAssertions already provides one
# (rails/test_help.rb includes it into every ActiveSupport::TestCase), and a
# narrower version here would shadow it suite-wide -- for all 8100+ tests, not
# just the ones that mean to use this module -- dropping its `include_schema:`
# keyword and its materialize_transactions step. Every call site uses Rails'
# own assert_no_queries unchanged.
module SqlCapture
  def capture_sql
    queries = []
    callback = ->(_n, _s, _f, _i, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end
end
