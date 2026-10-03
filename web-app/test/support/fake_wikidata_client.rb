# frozen_string_literal: true

# Stand-ins for Wikidata::Client and Wikipedia::Client with canned answers.
# Each records its calls so a test can assert what was (not) asked.
class FakeWikidataClient
  attr_reader :calls

  # entities: requested id => entity Hash (see WikidataEntityBuilder)
  # searches: name => [ids]; statements: [ids]; works: id => [titles]
  def initialize(entities: {}, searches: {}, statements: [], works: {}, labels: {}, country_codes: {}, works_error: nil, labels_error: nil)
    @entities = entities
    @searches = searches
    @statements = statements
    @works = works
    @labels = labels
    @country_codes = country_codes
    @works_error = works_error
    @labels_error = labels_error
    @calls = []
  end

  def entities(ids)
    @calls << [:entities, ids]
    ids.each_with_object({}) { |id, found| found[id] = @entities[id] if @entities.key?(id) }
  end

  def search(name)
    @calls << [:search, name]
    Array(@searches[name]).map { |id| {"id" => id, "label" => nil, "description" => nil} }
  end

  def by_statements(pairs)
    @calls << [:by_statements, pairs]
    @statements
  end

  def works(ids)
    @calls << [:works, ids]
    raise @works_error if @works_error

    @works.slice(*ids)
  end

  def labels(ids)
    @calls << [:labels, ids]
    raise @labels_error if @labels_error

    @labels.slice(*ids)
  end

  def country_codes(ids)
    @calls << [:country_codes, ids]
    @country_codes.slice(*ids)
  end

  def called?(method) = calls.any? { |call| call.first == method }
end

class FakeWikipediaClient
  attr_reader :calls

  # leads: [language, title] => Wikipedia::Lead, nil, or an exception to raise
  def initialize(leads = {})
    @leads = leads
    @calls = []
  end

  def lead(language:, title:)
    @calls << [language, title]
    value = @leads[[language, title]]
    raise value if value.is_a?(Exception)

    value
  end
end
