# Shared SQL capture for query-count assertions. Skips SCHEMA queries.
module SqlCapture
  def capture_sql
    queries = []
    callback = ->(_n, _s, _f, _i, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  def assert_no_queries(&block)
    queries = capture_sql(&block)
    assert_empty queries, "expected no queries, got:\n#{queries.join("\n")}"
  end
end
