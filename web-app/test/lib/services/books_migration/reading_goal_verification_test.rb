require "test_helper"

module Services
  module BooksMigration
    class ReadingGoalVerificationTest < ActiveSupport::TestCase
      LegacyGoal = Data.define(
        :id,
        :user_id,
        :start_date,
        :end_date,
        :number_of_books,
        :percentage_done
      )
      LegacyMembershipRelation = Data.define(:rows) do
        def pluck(*) = rows
      end

      setup do
        ::Books::ReadingGoal.delete_all
        @user = User.create!(email: "reading-goal-verification@example.com", role: :user)
        @read_list = ::Books::UserList.find_by!(user: @user, list_type: :read)
        @shared_book = books_books(:war_and_peace)
        @disagreement_book = books_books(:crime_and_punishment)
        @missing_book = books_books(:got)

        add_read_item(@shared_book, Date.new(2022, 5, 10), 1)
        add_read_item(@disagreement_book, Date.new(2022, 7, 15), 2)
        add_read_item(@missing_book, Date.new(2022, 11, 20), 3)

        @legacy_goals = [
          LegacyGoal.new(
            id: 101,
            user_id: @user.id,
            start_date: Date.new(2022, 1, 1),
            end_date: Date.new(2022, 12, 31),
            number_of_books: 4,
            percentage_done: BigDecimal(50)
          ),
          LegacyGoal.new(
            id: 102,
            user_id: @user.id,
            start_date: Date.new(2022, 4, 1),
            end_date: Date.new(2022, 6, 30),
            number_of_books: 2,
            percentage_done: BigDecimal(50)
          )
        ]
        @memberships = {
          101 => [
            [999_999_991, Date.new(2022, 3, 1)],
            [@shared_book.id, Date.new(2022, 5, 10)],
            [@disagreement_book.id, Date.new(2022, 8, 15)]
          ],
          102 => [[@shared_book.id, Date.new(2022, 5, 10)]]
        }

        create_imported_goal(id: 101, name: "Full year", public: true,
          starts_on: Date.new(2022, 1, 1), ends_on: Date.new(2022, 12, 31))
        create_imported_goal(id: 102, name: "Spring overlap", public: false,
          starts_on: Date.new(2022, 4, 1), ends_on: Date.new(2022, 6, 30))
        create_imported_goal(id: 15_000, name: "Legitimate new-app goal", public: true,
          starts_on: Date.new(2023, 1, 1), ends_on: Date.new(2023, 12, 31))
      end

      test "classifies each intentional live-projection repair independently" do
        result = run_verification(expected: {
          imported_goals: 2,
          distinct_owners: 1,
          public_goals: 1,
          id_range: 101..102
        })

        assert_predicate result, :success?
        assert_empty result.errors
        assert_equal 1, result.data[:repairs][:stale_memberships]
        assert_equal 1, result.data[:repairs][:date_disagreements]
        assert_equal 1, result.data[:repairs][:missing_qualifying_books]
        assert_equal 1, result.data[:repairs][:percentage_drift]
      end

      test "scopes definition totals to legacy ids and inspects forbidden target schema" do
        result = run_verification(expected: {
          imported_goals: 2,
          distinct_owners: 1,
          public_goals: 1,
          id_range: 101..102
        })

        assert_equal 2, result.data[:imported_goals]
        assert_equal 1, result.data[:distinct_owners]
        assert_equal 1, result.data[:public_goals]
        assert_equal 101..102, result.data[:id_range]
        assert_equal 0, result.data[:persisted_goal_book_rows]
        assert_equal 0, result.data[:persisted_percentage_columns]
      end

      test "the production report enforces the approved definition totals" do
        result = run_verification

        refute_predicate result, :success?
        assert_includes result.errors, "expected 399 imported goals, found 2"
        assert_includes result.errors, "expected 374 distinct owners, found 1"
        assert_includes result.errors, "expected 8 public goals, found 1"
        assert_includes result.errors, "expected imported id range 1..438, found 101..102"
      end

      test "missing imported owners and unrelated low target ids fail verification" do
        missing_user_id = User.maximum(:id).to_i + 1_000_000
        missing_owner_goal = LegacyGoal.new(
          id: 103,
          user_id: missing_user_id,
          start_date: Date.new(2022, 1, 1),
          end_date: Date.new(2022, 12, 31),
          number_of_books: 1,
          percentage_done: BigDecimal(0)
        )
        create_imported_goal(id: 99, name: "Unexpected low goal", public: false,
          starts_on: Date.new(2021, 1, 1), ends_on: Date.new(2021, 12, 31))

        result = run_verification(
          goals: @legacy_goals + [missing_owner_goal],
          memberships: @memberships.merge(103 => []),
          expected: {
            imported_goals: 2,
            distinct_owners: 1,
            public_goals: 1,
            id_range: 101..102
          }
        )

        refute_predicate result, :success?
        assert_equal 1, result.data[:missing_imported_owners]
        assert_equal [99], result.data[:unexpected_low_target_ids]
        assert_includes result.errors, "1 legacy goal owners have no migrated User"
        assert_includes result.errors, "unexpected target ids below 10000: 99"
      end

      private

      def add_read_item(book, completed_on, position)
        UserListItem.create!(
          user_list: @read_list,
          listable: book,
          completed_on: completed_on,
          position: position
        )
      end

      def create_imported_goal(id:, name:, public:, starts_on:, ends_on:)
        ::Books::ReadingGoal.create!(
          id: id,
          user: @user,
          name: name,
          target_count: 10,
          starts_on: starts_on,
          ends_on: ends_on,
          public: public
        )
      end

      def run_verification(goals: @legacy_goals, memberships: @memberships, expected: nil)
        LegacyBooks::ReadingGoal.expects(:all).once.returns(goals)
        memberships.each do |goal_id, rows|
          LegacyBooks::ReadingGoalBook.stubs(:where)
            .with(reading_goal_id: goal_id)
            .returns(LegacyMembershipRelation.new(rows: rows))
        end

        verifier = ReadingGoalVerification.new
        verifier.stubs(:expected_definition_totals).returns(expected) if expected
        verifier.call
      end
    end
  end
end
