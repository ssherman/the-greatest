require "test_helper"

module Services
  module Lists
    module Audits
      class QueueTest < ActiveSupport::TestCase
        setup do
          @admin = users(:admin_user)
          @approved = lists(:approved_list)
        end

        def audit!(list, status:, started_at:, verdict: nil)
          ListAudit.create!(
            list: list, user: @admin, status: status, verdict: verdict, started_at: started_at,
            finished_at: started_at, lease_expires_at: started_at + 1.hour
          )
        end

        test "an approved never-audited list is in the queue" do
          assert_includes Queue.relation, @approved
        end

        test "lists with a finished audit are not, whichever the verdict" do
          assert_not_includes Queue.relation, lists(:books_list)
          audit!(@approved, status: :finished, verdict: :unverifiable, started_at: 1.day.ago)
          assert_not_includes Queue.relation, @approved
        end

        test "unapproved and generated lists are not" do
          generated = ::Books::List.create!(name: "Gen", status: :approved, auto_generated_kind: :year_top, auto_generated_year: 2001)
          assert_not_includes Queue.relation, lists(:basic_list)
          assert_not_includes Queue.relation, generated
        end

        test "a list with an open audit is not, but one with an expired audit is" do
          audit = ListAudit.create!(list: @approved, user: @admin, started_at: Time.current, lease_expires_at: 3.hours.from_now)
          assert_not_includes Queue.relation, @approved
          audit.update!(lease_expires_at: 1.minute.ago)
          assert_includes Queue.relation, @approved
        end

        test "a released list sorts after every never-started list" do
          audit!(@approved, status: :released, started_at: 1.day.ago)
          ids = Queue.relation.map(&:id)
          assert_equal @approved.id, ids.last
          assert_operator ids.size, :>, 1
        end

        test "released lists sort by earliest last start" do
          audit!(lists(:high_quality_list), status: :released, started_at: 1.hour.ago)
          audit!(@approved, status: :released, started_at: 2.days.ago)
          ids = Queue.relation.map(&:id)
          assert_operator ids.index(@approved.id), :<, ids.index(lists(:high_quality_list).id)
        end

        test "heavier lists come first among never-started ones" do
          config = ::Books::RankingConfiguration.default_primary
          RankedList.create!(list: @approved, ranking_configuration: config, weight: 10)
          RankedList.create!(list: lists(:high_quality_list), ranking_configuration: config, weight: 90)
          ids = Queue.relation.map(&:id)
          assert_operator ids.index(lists(:high_quality_list).id), :<, ids.index(@approved.id)
        end

        test "remaining counts the relation" do
          assert_equal Queue.relation.to_a.size, Queue.remaining
        end

        test "works without a default primary configuration" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)
          assert_includes Queue.relation, @approved
        end
      end
    end
  end
end
