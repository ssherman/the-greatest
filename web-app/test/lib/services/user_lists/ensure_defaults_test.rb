# frozen_string_literal: true

require "test_helper"
require "active_record/testing/query_assertions"

module Services
  module UserLists
    class EnsureDefaultsTest < ActiveSupport::TestCase
      include ActiveRecord::Assertions::QueryAssertions

      # admin_user owns exactly one fixture list (a games favorites) and no books
      # lists, so it starts from a clean slate for this domain. Do NOT switch to
      # regular_user — Task 4 gives it books fixtures, which would break the
      # "creates every missing default" assertion below.
      setup do
        @user = users(:admin_user)
        assert_equal [], @user.user_lists.where(type: "Books::UserList").to_a
      end

      def books_lists
        @user.user_lists.where(type: "Books::UserList").to_a
      end

      test "creates every missing default for the domain" do
        assert_equal [], books_lists

        result = EnsureDefaults.call(user: @user, domain: :books, existing: [])

        assert_equal 4, result.size
        assert_equal %w[favorites read reading want_to_read].sort,
          result.map(&:list_type).sort
        assert result.all? { |list| list.is_a?(::Books::UserList) }
      end

      test "uses the subclass's default names" do
        EnsureDefaults.call(user: @user, domain: :books, existing: [])
        # Queried via the Books::UserList subclass, not the base-class
        # @user.user_lists association: the list_type enum is declared per
        # subclass, so a symbol value only casts correctly through the
        # subclass's own relation.
        list = ::Books::UserList.find_by(user: @user, list_type: :favorites)
        assert_equal "My Favorite Books", list.name
      end

      test "is idempotent and writes nothing on a second call" do
        EnsureDefaults.call(user: @user, domain: :books, existing: [])
        existing = books_lists

        assert_no_difference "UserList.count" do
          result = EnsureDefaults.call(user: @user, domain: :books, existing: existing)
          assert_equal existing.map(&:id).sort, result.map(&:id).sort
        end
      end

      test "issues zero queries when the set is already complete" do
        EnsureDefaults.call(user: @user, domain: :books, existing: [])
        existing = books_lists

        assert_queries_count(0) do
          EnsureDefaults.call(user: @user, domain: :books, existing: existing)
        end
      end

      test "fills only the gap when some defaults already exist" do
        ::Books::UserList.create!(user: @user, list_type: :favorites, name: "My Favorite Books")

        result = EnsureDefaults.call(user: @user, domain: :books, existing: books_lists)

        assert_equal 4, result.size
        assert_equal 4, books_lists.size
      end

      test "touches only the requested domain" do
        before = @user.user_lists.where.not(type: "Books::UserList").count

        EnsureDefaults.call(user: @user, domain: :books, existing: [])

        assert_equal before, @user.user_lists.where.not(type: "Books::UserList").count
      end

      test "returns the existing set for a domain with no subclasses" do
        existing = []
        assert_equal existing, EnsureDefaults.call(user: @user, domain: :nope, existing: existing)
      end

      test "survives losing the create race to a concurrent request" do
        winner = ::Books::UserList.create!(user: @user, list_type: :favorites, name: "My Favorite Books")
        # Simulate the other request having committed between our diff and our write:
        # find_or_create_by! trips one_default_per_type_per_user and raises.
        ::Books::UserList.stubs(:find_or_create_by!)
          .raises(ActiveRecord::RecordInvalid.new(::Books::UserList.new))

        result = nil
        assert_nothing_raised do
          result = EnsureDefaults.call(user: @user, domain: :books, existing: [])
        end

        # The three it could not create are dropped; the one that already exists is re-read.
        assert_equal [winner.id], result.map(&:id)
      end
    end
  end
end
