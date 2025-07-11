# == Schema Information
#
# Table name: movies_people
#
#  id          :bigint           not null, primary key
#  born_on     :date
#  country     :string(2)
#  description :text
#  died_on     :date
#  gender      :integer
#  name        :string           not null
#  slug        :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_movies_people_on_gender  (gender)
#  index_movies_people_on_slug    (slug) UNIQUE
#
require "test_helper"

module Movies
  class PersonTest < ActiveSupport::TestCase
    def setup
      @person = movies_people(:godfather_director)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @person.valid?
    end

    test "should require name" do
      @person.name = nil
      assert_not @person.valid?
      assert_includes @person.errors[:name], "can't be blank"
    end

    test "should validate country is 2 characters if present" do
      @person.country = "USA"
      assert_not @person.valid?
      assert_includes @person.errors[:country], "is the wrong length (should be 2 characters)"
    end

    test "should allow nil country" do
      @person.country = nil
      assert @person.valid?
    end

    test "should allow nil gender" do
      @person.gender = nil
      assert @person.valid?
    end

    test "should validate died_on is after born_on" do
      @person.born_on = Date.new(2000, 1, 1)
      @person.died_on = Date.new(1990, 1, 1)
      assert_not @person.valid?
      assert_includes @person.errors[:died_on], "must be after date of birth"
    end

    # Enums
    test "should have correct gender enum values" do
      assert_equal 0, Movies::Person.genders["male"]
      assert_equal 1, Movies::Person.genders["female"]
      assert_equal 2, Movies::Person.genders["non_binary"]
      assert_equal 3, Movies::Person.genders["other"]
    end

    # Associations
    test "should have credits association" do
      assert_respond_to @person, :credits
    end

    test "should have memberships association" do
      assert_respond_to @person, :memberships
    end
  end
end
