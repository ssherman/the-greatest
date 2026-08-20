require "test_helper"

module LegacyBooks
  class BlogPostTest < ActiveSupport::TestCase
    test "reads from the legacy blog_posts table" do
      assert_equal "blog_posts", BlogPost.table_name
    end

    # `.allocate` (not `.new`) deliberately: LegacyBooks::Record's `connects_to`
    # is skipped in test (see its comment), so any real instantiation of a
    # LegacyBooks model in test falls back to the app's own primary test
    # connection, which has no `blog_posts` table and raises PG::UndefinedTable
    # on schema introspection. `.allocate` skips `initialize` (no schema load)
    # while still calling the real, class-defined `readonly?` method.
    test "is read only" do
      assert_predicate BlogPost.allocate, :readonly?
    end

    # Verifies the *polymorphic type* used to key rich_text_content, without
    # instantiating a BlogPost (same schema-load problem as above -- reflection
    # metadata is available without a DB round trip; `.association(...).scope.to_sql`
    # is not).
    #
    # record_type in the legacy DB holds the un-namespaced literal "BlogPost" --
    # the old app's class name -- not "LegacyBooks::BlogPost". Rails derives the
    # polymorphic type from `polymorphic_name` by default, which would produce
    # the namespaced string and match zero rows. This is the assertion that
    # pins the fix.
    test "rich_text_content is keyed by the legacy un-namespaced class name" do
      reflection = BlogPost.reflect_on_association(:rich_text_content)

      assert_equal "LegacyBooks::RichText", reflection.klass.name
      assert_equal "record_id", reflection.foreign_key
      assert_equal "record_type", reflection.type
      assert_equal "BlogPost", BlogPost.polymorphic_name
    end

    # The scope is inspected rather than executed: instance_exec'ing it against a
    # bare object that only responds to :where records the filter without ever
    # touching ActiveRecord's query builder or the schema cache -- which is what
    # makes this safe in an environment where LegacyBooks models have no usable
    # connection (see the comment on the readonly? test above).
    #
    # ActionText's unique index is (record_type, record_id, name), so more than
    # one named field per record is representable; this filter is what keeps
    # rich_text_content reading the right row.
    test "rich_text_content is filtered to the content field" do
      captured = nil
      recorder = Object.new
      recorder.define_singleton_method(:where) { |*args| captured = args }

      recorder.instance_exec(&BlogPost.reflect_on_association(:rich_text_content).scope)

      assert_equal [{name: "content"}], captured
    end

    test "rich_text_content reads the legacy ActionText table" do
      assert_equal "action_text_rich_texts", RichText.table_name
    end
  end
end
