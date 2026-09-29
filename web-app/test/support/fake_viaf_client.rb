# frozen_string_literal: true

# A stand-in for Viaf::Client with canned answers. Records its calls so a test
# can assert what was (not) asked.
class FakeViafClient
  attr_reader :calls

  # suggestions: query => [Viaf::Suggestion], or an exception to raise.
  # people: viaf id => Viaf::Person, or an exception to raise. An id with no
  # entry answers NotFoundError, as VIAF does.
  def initialize(suggestions: {}, people: {})
    @suggestions = suggestions
    @people = people.transform_keys(&:to_s)
    @calls = []
  end

  def suggest(query)
    @calls << [:suggest, query]
    value = @suggestions.fetch(query, [])
    raise value if value.is_a?(Exception)

    value
  end

  def cluster(viaf_id, refresh: false)
    @calls << [:cluster, viaf_id.to_s, refresh]
    value = @people[viaf_id.to_s]
    raise value if value.is_a?(Exception)
    raise ::Viaf::Exceptions::NotFoundError.new("Not found", 404) if value.nil?

    value
  end

  def called?(method) = calls.any? { |call| call.first == method }

  def clusters = cluster_calls.map { |call| call[1] }

  def refreshes = cluster_calls.map { |call| call[2] }

  private

  def cluster_calls = calls.select { |call| call.first == :cluster }
end
