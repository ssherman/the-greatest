require "test_helper"

class CorrectableTest < ActiveSupport::TestCase
  # A throwaway class, so this tests the concern rather than Books::Book's
  # particular declarations -- which are free to change without breaking this.
  class Dummy
    include ActiveModel::Model
    extend ActiveModel::Callbacks

    def self.has_many(*, **) = nil
    include Correctable

    correctable_field :name, type: :string
    correctable_field :year, type: :integer, label: "Year of release", hint: "A four-digit year"
    correctable_field :blurb, type: :text, target: :description
  end

  class OtherDummy
    include ActiveModel::Model

    def self.has_many(*, **) = nil
    include Correctable

    correctable_field :headline, type: :string
  end

  # A second throwaway pair, related by inheritance this time. `ActiveSupport::Concern`
  # runs `included do ... end` once per direct includer, so Dummy and OtherDummy above
  # each get their own `class_attribute` default and can never share it -- that pair
  # cannot catch a `correctable_field` that mutates the hash in place instead of
  # reassigning it. Child never calls `include Correctable` itself; it inherits Parent's
  # `correctable_fields` getter, so Child's first `correctable_field` call reads the
  # exact same Hash object Parent holds. That is the shape that catches mutation.
  class Parent
    include ActiveModel::Model

    def self.has_many(*, **) = nil
    include Correctable

    correctable_field :parent_field, type: :string
  end

  class Child < Parent
    correctable_field :child_field, type: :string
  end

  test "records declarations in declaration order" do
    assert_equal %w[name year blurb], Dummy.correctable_field_names
  end

  test "defaults target to column" do
    assert_equal :column, Dummy.correctable_fields["name"].target
  end

  test "carries an explicit target" do
    assert_equal :description, Dummy.correctable_fields["blurb"].target
  end

  test "defaults label to a humanized name" do
    assert_equal "Name", Dummy.correctable_fields["name"].label
  end

  test "carries an explicit label and hint" do
    definition = Dummy.correctable_fields["year"]
    assert_equal ["Year of release", "A four-digit year"], [definition.label, definition.hint]
  end

  test "rejects an unknown type" do
    assert_raises(ArgumentError) do
      Class.new do
        def self.has_many(*, **) = nil
        include Correctable
      end.correctable_field(:x, type: :nonsense)
    end
  end

  test "rejects an unknown target" do
    assert_raises(ArgumentError) do
      Class.new do
        def self.has_many(*, **) = nil
        include Correctable
      end.correctable_field(:x, type: :string, target: :nonsense)
    end
  end

  # Sibling classes: cheap, and documents intent, but cannot actually catch a mutating
  # `correctable_field` -- see the comment on Parent/Child above for why. Kept anyway;
  # the subclass test below is the one with teeth.
  test "one class's declarations do not leak into another" do
    assert_equal %w[headline], OtherDummy.correctable_field_names
    assert_not_includes Dummy.correctable_field_names, "headline"
  end

  # The hazard this guards against: class_attribute's default hash, once a subclass
  # inherits it unmodified, IS the superclass's own object. `correctable_field`
  # mutating it in place (`correctable_fields[name] = definition`) rather than
  # reassigning (`self.correctable_fields = correctable_fields.merge(...)`) would add
  # Child's field to Parent too.
  test "a subclass's declarations do not leak into its superclass" do
    assert_includes Child.correctable_field_names, "child_field"
    assert_not_includes Parent.correctable_field_names, "child_field"
  end

  test "correction_applied is a no-op by default" do
    assert_nil Dummy.new.correction_applied(%w[name])
  end
end
