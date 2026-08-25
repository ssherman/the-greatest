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

  # class_attribute's default object is shared by every including class. If
  # correctable_field mutated it in place, declaring a field on one model would
  # add it to every other correctable model in the app.
  test "one class's declarations do not leak into another" do
    assert_equal %w[headline], OtherDummy.correctable_field_names
    assert_not_includes Dummy.correctable_field_names, "headline"
  end

  test "correction_applied is a no-op by default" do
    assert_nil Dummy.new.correction_applied(%w[name])
  end
end
