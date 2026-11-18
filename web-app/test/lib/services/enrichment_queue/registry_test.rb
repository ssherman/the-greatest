require "test_helper"

module Services
  module EnrichmentQueue
    class RegistryTest < ActiveSupport::TestCase
      test "fetch finds a type by kind and raises on an unknown one" do
        Registry.stubs(:types).returns([EnrichmentQueueTestType])
        assert_equal EnrichmentQueueTestType, Registry.fetch("books.test_type")
        assert_raises(Registry::UnknownKind) { Registry.fetch("books.nope") }
      end

      test "for_domain and find scope by domain and slug" do
        Registry.stubs(:types).returns([EnrichmentQueueTestType])
        assert_equal [EnrichmentQueueTestType], Registry.for_domain("books")
        assert_empty Registry.for_domain("music")
        assert_equal EnrichmentQueueTestType, Registry.find(domain: "books", slug: "test_type")
        assert_nil Registry.find(domain: "books", slug: "nope")
      end

      test "every registered type answers the whole interface" do
        assert_operator Registry.types.size, :>=, 1
        Registry.types.each do |type|
          assert_match ::Enrichment::KIND_FORMAT, type.kind
          assert_kind_of Integer, type.version
          assert type.label.present?
          assert_kind_of Hash, type.answer_schema
          assert_equal type.answer_schema, type.reference["answer_schema"]
          assert_operator type.target_class, :<, ApplicationRecord
          assert_kind_of String, type.priority_sql
          assert type.priority_sql.present?
        end
      end

      test "domain and slug derive from kind" do
        assert_equal "books", EnrichmentQueueTestType.domain
        assert_equal "test_type", EnrichmentQueueTestType.slug
      end

      test "a type that defines nothing raises NotImplementedError" do
        assert_raises(NotImplementedError) { Class.new(Type).kind }
      end

      test "prompt_locals defaults to an empty hash" do
        assert_equal({}, EnrichmentQueueTestType.prompt_locals)
      end
    end
  end
end
