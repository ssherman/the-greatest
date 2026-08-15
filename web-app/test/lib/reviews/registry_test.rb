require "test_helper"

module Reviews
  class RegistryTest < ActiveSupport::TestCase
    test "resolves the books domain to its reviewable types" do
      assert_equal ["Books::Book"], Registry.types_for(:books)
      assert_equal [::Books::Book], Registry.classes_for(:books)
    end

    test "a domain with no reviewable types resolves to empty" do
      assert_empty Registry.types_for(:music)
      assert_empty Registry.classes_for(:nope)
    end

    test "accepts a string domain as well as a symbol" do
      assert_equal ["Books::Book"], Registry.types_for("books")
    end

    test "allowed? gates arbitrary user-supplied types" do
      assert Registry.allowed?("Books::Book")
      refute Registry.allowed?("User")
      refute Registry.allowed?(nil)
    end

    # DOMAIN_TYPES and ADMIN_PATHS are two separate hashes keyed by the same
    # reviewable type string, and nothing enforces they stay in step. Forgetting
    # an ADMIN_PATHS entry for a type that's already in DOMAIN_TYPES degrades
    # silently: admin_path_for returns nil, Admin::ReviewsHelper's
    # cross_domain_review_url returns nil right after it, and every review of
    # that type on /admin/users/:id renders as unlinked plain text -- no error,
    # no test failure -- which is exactly the half-wired failure mode this
    # class's own header comment says it exists to prevent. Mirrors
    # test/lib/admin/domain_nav_test.rb's "nav items all carry a label, path and
    # icon", which asserts the same kind of cross-table completeness.
    test "every DOMAIN_TYPES entry has a matching ADMIN_PATHS entry" do
      Registry::DOMAIN_TYPES.each do |domain, types|
        types.each do |type|
          assert Registry::ADMIN_PATHS.key?(type),
            "#{type} is registered under DOMAIN_TYPES[#{domain.inspect}] but has no " \
            "ADMIN_PATHS entry -- admin_path_for(#{type}) will return nil"
        end
      end
    end
  end
end
