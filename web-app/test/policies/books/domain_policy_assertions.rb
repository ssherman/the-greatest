module Books
  module DomainPolicyAssertions
    def assert_books_domain_policy(policy_class, record)
      assert policy_class.new(users(:admin_user), record).index?
      assert policy_class.new(users(:admin_user), record).show?
      assert policy_class.new(users(:admin_user), record).create?
      assert policy_class.new(users(:admin_user), record).update?
      assert policy_class.new(users(:admin_user), record).destroy?
      assert policy_class.new(users(:admin_user), record).manage?

      assert policy_class.new(users(:editor_user), record).show?
      assert policy_class.new(users(:editor_user), record).update?
      assert policy_class.new(users(:editor_user), record).destroy?
      refute policy_class.new(users(:editor_user), record).manage?

      refute policy_class.new(nil, record).show?
      refute policy_class.new(users(:regular_user), record).show?
      refute policy_class.new(books_user(:viewer), record).manage?

      assert policy_class.new(books_user(:viewer), record).show?
      refute policy_class.new(books_user(:viewer), record).update?
      refute policy_class.new(books_user(:viewer), record).destroy?

      assert policy_class.new(books_user(:editor), record).update?
      refute policy_class.new(books_user(:editor), record).destroy?

      assert policy_class.new(books_user(:moderator), record).destroy?
      refute policy_class.new(books_user(:moderator), record).manage?

      assert policy_class.new(books_user(:admin), record).manage?
    end

    def assert_books_scope(policy_class, model)
      assert_equal model.count, policy_class::Scope.new(users(:admin_user), model).resolve.count
      assert_equal model.count, policy_class::Scope.new(books_user(:viewer), model).resolve.count
      assert_empty policy_class::Scope.new(users(:regular_user), model).resolve
      assert_empty policy_class::Scope.new(nil, model).resolve
    end

    def books_user(permission_level)
      @books_users ||= {}
      @books_users[permission_level] ||= begin
        user = User.create!(
          email: "books-#{permission_level}@example.com",
          name: "Books #{permission_level}",
          role: :user
        )
        user.domain_roles.create!(domain: :books, permission_level: permission_level)
        user
      end
    end

    def music_user
      @music_user ||= users(:contractor_user)
    end
  end
end
