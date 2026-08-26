require "test_helper"

module Services
  module Corrections
    class TypeRegistryTest < ActiveSupport::TestCase
      test "resolves a registered correctable type" do
        assert_equal ::Books::Book, TypeRegistry.resolve("Books::Book")
      end

      test "returns nil for a type that is not in the registry" do
        assert_nil TypeRegistry.resolve("User")
      end

      # The whole point: legacy called constantize on this param directly.
      test "returns nil rather than constantizing an arbitrary class name" do
        assert_nil TypeRegistry.resolve("Kernel")
        assert_nil TypeRegistry.resolve("ActiveRecord::Base")
      end

      test "returns nil for a registered type that is not correctable" do
        # Books::Edition is in Admin::DomainRouting::ENTITIES but does not
        # include Correctable.
        assert_nil TypeRegistry.resolve("Books::Edition")
      end

      test "returns nil for blank input" do
        assert_nil TypeRegistry.resolve(nil)
        assert_nil TypeRegistry.resolve("")
      end

      test "reports the domain for a type" do
        assert_equal :books, TypeRegistry.domain_for("Books::Book")
      end

      test "lists the correctable types for a domain" do
        assert_equal ["Books::Book"], TypeRegistry.types_for_domain(:books)
      end

      # movies, not music: Task 16 wired Music::Album into Admin::DomainRouting::
      # ENTITIES, so music no longer has an empty list here. movies has no entry
      # in ENTITIES at all -- it is out of scope for corrections -- so it is the
      # one domain guaranteed to stay empty.
      test "lists nothing for a domain with no correctable types" do
        assert_empty TypeRegistry.types_for_domain(:movies)
      end
    end
  end
end
