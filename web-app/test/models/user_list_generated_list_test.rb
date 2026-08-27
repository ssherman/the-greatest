# frozen_string_literal: true

require "test_helper"

class UserListGeneratedListTest < ActiveSupport::TestCase
  test "generating_subclasses covers books, albums, songs and games" do
    assert_equal(
      ["Books::UserList", "Games::UserList", "Music::Albums::UserList", "Music::Songs::UserList"],
      UserList.generating_subclasses.map(&:name).sort
    )
  end

  test "every generating subclass declares a list class, name and description" do
    UserList.generating_subclasses.each do |klass|
      assert_operator klass.generated_list_class, :<, ::List,
        "#{klass.name}.generated_list_class must be a List subclass"
      assert_predicate klass.generated_list_name, :present?
      assert_predicate klass.generated_list_description, :present?
    end
  end

  test "the generated list class matches the domain's listable" do
    assert_equal ::Books::List, ::Books::UserList.generated_list_class
    assert_equal ::Music::Albums::List, ::Music::Albums::UserList.generated_list_class
    assert_equal ::Music::Songs::List, ::Music::Songs::UserList.generated_list_class
    assert_equal ::Games::List, ::Games::UserList.generated_list_class
  end

  test "the base class refuses to answer for a subclass that has not declared one" do
    assert_raises(NotImplementedError) { UserList.generated_list_class }
    assert_raises(NotImplementedError) { UserList.generated_list_name }
    assert_raises(NotImplementedError) { UserList.generated_list_description }
  end
end
