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
  end
end
