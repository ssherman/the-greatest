# == Schema Information
#
# Table name: movies_credits
#
#  id              :bigint           not null, primary key
#  character_name  :string
#  creditable_type :string           not null
#  position        :integer
#  role            :integer          default("director"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  creditable_id   :bigint           not null
#  person_id       :bigint           not null
#
# Indexes
#
#  index_movies_credits_on_creditable                         (creditable_type,creditable_id)
#  index_movies_credits_on_creditable_type_and_creditable_id  (creditable_type,creditable_id)
#  index_movies_credits_on_person_id                          (person_id)
#  index_movies_credits_on_person_id_and_role                 (person_id,role)
#
# Foreign Keys
#
#  fk_rails_...  (person_id => movies_people.id)
#
require "test_helper"

module Movies
  class CreditTest < ActiveSupport::TestCase
    def setup
      @movie = movies_movies(:godfather)
      @person = movies_people(:godfather_director)
      @credit = Credit.new(
        person: @person,
        creditable: @movie,
        role: :director,
        position: 1
      )
    end

    test "should be valid with valid attributes" do
      assert @credit.valid?
    end

    test "should require a person" do
      @credit.person = nil
      assert_not @credit.valid?
      assert_includes @credit.errors[:person], "must exist"
    end

    test "should require a creditable" do
      @credit.creditable = nil
      assert_not @credit.valid?
      assert_includes @credit.errors[:creditable], "must exist"
    end

    test "should require a role" do
      @credit.role = nil
      assert_not @credit.valid?
      assert_includes @credit.errors[:role], "can't be blank"
    end

    test "should accept valid roles" do
      valid_roles = [:director, :producer, :screenwriter, :actor, :actress]
      valid_roles.each do |role|
        @credit.role = role
        assert @credit.valid?, "#{role} should be a valid role"
      end
    end

    test "should reject invalid roles" do
      # Rails enums don't allow invalid values, so we test the validation differently
      assert_raises(ArgumentError) do
        @credit.role = :invalid_role
      end
    end

    test "should accept valid position values" do
      @credit.position = 1
      assert @credit.valid?

      @credit.position = 10
      assert @credit.valid?
    end

    test "should reject invalid position values" do
      @credit.position = 0
      assert_not @credit.valid?
      assert_includes @credit.errors[:position], "must be greater than 0"

      @credit.position = -1
      assert_not @credit.valid?
    end

    test "should allow nil position" do
      @credit.position = nil
      assert @credit.valid?
    end

    test "should allow character name for actors" do
      @credit.role = :actor
      @credit.character_name = "Don Vito Corleone"
      assert @credit.valid?
    end

    test "should belong to a person" do
      assert_respond_to @credit, :person
      assert_instance_of Person, @credit.person
    end

    test "should belong to a creditable polymorphically" do
      assert_respond_to @credit, :creditable
      assert_instance_of Movie, @credit.creditable
    end

    test "should work with release as creditable" do
      release = movies_releases(:godfather_theatrical)
      credit = Credit.new(
        person: @person,
        creditable: release,
        role: :director
      )
      assert credit.valid?
      assert_instance_of Release, credit.creditable
    end

    test "by_role scope should filter by role" do
      director_credit = Credit.create!(
        person: @person,
        creditable: @movie,
        role: :director
      )

      actor_credit = Credit.create!(
        person: movies_people(:al_pacino),
        creditable: @movie,
        role: :actor
      )

      director_credits = Credit.by_role(:director)
      assert_includes director_credits, director_credit
      assert_not_includes director_credits, actor_credit
    end

    test "ordered_by_position scope should order by position" do
      # Clear existing credits for this test to avoid interference
      Credit.where(creditable: @movie).destroy_all

      credit1 = Credit.create!(
        person: @person,
        creditable: @movie,
        role: :director,
        position: 2
      )

      credit2 = Credit.create!(
        person: movies_people(:al_pacino),
        creditable: @movie,
        role: :actor,
        position: 1
      )

      ordered_credits = Credit.where(creditable: @movie).ordered_by_position
      assert_equal [credit2, credit1], ordered_credits.to_a
    end

    test "for_movie scope should filter by movie" do
      other_movie = movies_movies(:shawshank)

      movie_credit = Credit.create!(
        person: @person,
        creditable: @movie,
        role: :director
      )

      other_credit = Credit.create!(
        person: @person,
        creditable: other_movie,
        role: :director
      )

      movie_credits = Credit.for_movie(@movie)
      assert_includes movie_credits, movie_credit
      assert_not_includes movie_credits, other_credit
    end

    test "for_release scope should filter by release" do
      release = movies_releases(:godfather_theatrical)
      other_release = movies_releases(:shawshank_theatrical)

      release_credit = Credit.create!(
        person: @person,
        creditable: release,
        role: :director
      )

      other_credit = Credit.create!(
        person: @person,
        creditable: other_release,
        role: :director
      )

      release_credits = Credit.for_release(release)
      assert_includes release_credits, release_credit
      assert_not_includes release_credits, other_credit
    end
  end
end
