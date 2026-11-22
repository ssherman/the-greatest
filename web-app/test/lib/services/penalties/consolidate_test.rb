require "test_helper"

module Services
  module Penalties
    class ConsolidateTest < ActiveSupport::TestCase
      OLD = {
        15 => "List: only covers 1 specific location",
        21 => "Voters: specific voter details are lacking",
        27 => "List: only covers genre fiction(multiple genres)",
        31 => "List: only partially covers 1 specific country",
        32 => "Voters: half the voters are not critics, authors, or experts",
        36 => "List: only covers 1 specific continent",
        37 => "List: only covers 1 specific country",
        38 => "List: only covers 1 specific large geographical region (Asia, Latin America, etc)",
        39 => "List: only covers 1 specific state of a country",
        42 => "List: only covers 1 specific city",
        44 => "Voters: not critics, authors, or experts, but the books on the list were curated by critics/experts",
        46 => "List: only covers 1 specific small geographical region (Southern United States, etc)"
      }.freeze

      # Production ids, created explicitly: fixture ids are hashed, and the
      # service looks penalties up by the ids the consolidation decisions name.
      setup do
        OLD.each do |id, name|
          attrs = {id: id, name: name, category: :list_subject_scope}
          if id == 15
            ::Global::Penalty.create!(attrs.merge(dynamic_type: :location_specific))
          else
            ::Books::Penalty.create!(attrs)
          end
        end
        @books = ranking_configurations(:books_global)
        @books_user = ranking_configurations(:books_user)
        @music = ranking_configurations(:music_albums_global)
        @list = lists(:basic_list)
        @other_list = lists(:another_list)
        [@list, @other_list].each { |l| l.update_columns(location_specific: nil) }
      end

      def attach(list, penalty_id)
        ::ListPenalty.create!(list: list, penalty_id: penalty_id)
      end

      def apply_value(config, penalty_id, value)
        ::PenaltyApplication.create!(ranking_configuration: config, penalty_id: penalty_id, value: value)
      end

      def value_of(config, penalty_id)
        ::PenaltyApplication.find_by(ranking_configuration: config, penalty_id: penalty_id)&.value
      end

      def snapshot
        [::Penalty.order(:id).pluck(:id, :name),
          ::ListPenalty.order(:id).pluck(:list_id, :penalty_id),
          ::PenaltyApplication.order(:id).pluck(:penalty_id, :ranking_configuration_id, :value),
          ::List.order(:id).pluck(:id, :location_specific)]
      end

      test "dry run reports the plan and writes nothing" do
        attach(@list, 37)
        attach(@list, 32)
        apply_value(@books, 37, 30)
        before = snapshot

        result = Consolidate.call(dry_run: true)

        assert result.success?
        assert_equal before, snapshot
        assert_equal [{id: @list.id, name: @list.name}], result.data[:lists_flagged]
        deleted = result.data[:penalties_deleted].index_by { |d| d[:id] }
        assert_equal 1, deleted[37][:lists]
        assert_equal 1, deleted[32][:lists]
        assert_includes result.data[:penalties_renamed].map { |r| r[:id] }, 44
        refute result.data[:nothing_to_do]
      end

      test "apply flags every list carrying a geography penalty" do
        [31, 36, 37, 38, 39, 42, 46].each { |id| attach(@list, id) }
        attach(@other_list, 21)

        Consolidate.call(dry_run: false)

        assert @list.reload.location_specific
        refute @other_list.reload.location_specific
      end

      test "apply moves state and city lists to the small area penalty without duplicates" do
        attach(@list, 39)
        attach(@list, 42)
        attach(@other_list, 42)
        attach(@other_list, 46)

        Consolidate.call(dry_run: false)

        assert_equal [46], @list.reload.list_penalties.pluck(:penalty_id)
        assert_equal [46], @other_list.reload.list_penalties.pluck(:penalty_id)
      end

      test "apply moves 32 to 44 and skips a list that already has 44" do
        attach(@list, 32)
        attach(@other_list, 32)
        attach(@other_list, 44)

        Consolidate.call(dry_run: false)

        assert_equal [44], @list.reload.list_penalties.pluck(:penalty_id)
        assert_equal [44], @other_list.reload.list_penalties.pluck(:penalty_id)
      end

      test "apply deletes the retired penalties with their attachments and applications" do
        attach(@list, 21)
        attach(@list, 36)
        apply_value(@books, 36, 10)
        apply_value(@books, 21, 5)

        result = Consolidate.call(dry_run: false)

        assert_empty ::Penalty.where(id: [21, 27, 31, 32, 36, 37, 38, 39, 42])
        assert_equal [15, 44, 46], ::Penalty.where(id: OLD.keys).order(:id).pluck(:id)
        assert_empty ::ListPenalty.where(list: @list)
        assert_nil value_of(@books, 21)
        deleted = result.data[:penalties_deleted].index_by { |d| d[:id] }
        assert_equal 1, deleted[21][:lists]
        assert_equal 1, deleted[36][:lists]
      end

      test "location flag takes the country value, else 20, on books configurations only" do
        apply_value(@books, 37, 30)
        apply_value(@books_user, 42, 40)
        apply_value(@music, 15, 40)

        Consolidate.call(dry_run: false)

        assert_equal 30, value_of(@books, 15)
        assert_equal 20, value_of(@books_user, 15)
        assert_equal 40, value_of(@music, 15)
        assert_nil value_of(@music, 46)
      end

      test "the small area penalty is set to 15 only where a geography application existed" do
        apply_value(@books, 42, 40)
        apply_value(@books_user, 46, 99)

        Consolidate.call(dry_run: false)

        assert_equal 15, value_of(@books, 46)
        assert_equal 15, value_of(@books_user, 46)
        assert_nil value_of(ranking_configurations(:books_inherited), 46)
      end

      test "apply renames 44 and 46" do
        Consolidate.call(dry_run: false)

        assert_equal "Voters: a mix of experts and the public", ::Penalty.find(44).name
        assert_equal "voter_expertise", ::Penalty.find(44).category
        assert_equal "List: only covers an area smaller than a country (a state, city or region)", ::Penalty.find(46).name
        assert_equal "list_subject_scope", ::Penalty.find(46).category
        assert ::Penalty.find(46).description.start_with?("Restricted to an area smaller than a country")
      end

      test "a second apply does nothing and keeps the values the first one set" do
        attach(@list, 37)
        attach(@list, 39)
        attach(@list, 32)
        apply_value(@books, 37, 30)
        Consolidate.call(dry_run: false)
        before = snapshot

        result = Consolidate.call(dry_run: false)

        assert result.success?
        assert_equal before, snapshot
        assert_equal 30, value_of(@books, 15)
        assert result.data[:nothing_to_do]
        assert_empty result.data[:penalties_deleted]
        assert_empty result.data[:lists_flagged]
        assert_empty result.data[:applications_set]
        assert_empty result.data[:penalties_renamed]
        assert_empty result.data[:attachments_moved]
      end

      test "an edit to the renamed penalty text survives a re-run" do
        Consolidate.call(dry_run: false)
        ::Penalty.find(46).update_columns(description: "Edited by an admin")

        Consolidate.call(dry_run: false)

        assert_equal "Edited by an admin", ::Penalty.find(46).description
      end

      test "an existing location value with no legacy geography application is kept" do
        apply_value(@books, 15, 33)

        Consolidate.call(dry_run: false)

        assert_equal 33, value_of(@books, 15)
      end

      test "an existing location value is replaced from the country value when legacy applications exist" do
        apply_value(@books, 15, 5)
        apply_value(@books, 37, 25)

        Consolidate.call(dry_run: false)

        assert_equal 25, value_of(@books, 15)
      end

      test "a wrong name at a known id refuses the whole run" do
        ::Penalty.find(37).update_columns(name: "Something else entirely")
        attach(@list, 39)

        result = Consolidate.call(dry_run: false)

        refute result.success?
        assert_match(/37/, result.errors.join)
        assert_match(/Something else entirely/, result.errors.join)
        assert_equal [39], @list.reload.list_penalties.pluck(:penalty_id)
        assert ::Penalty.exists?(21)
      end
    end
  end
end
