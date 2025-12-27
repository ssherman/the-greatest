# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      class StateManagerTest < ActiveSupport::TestCase
        setup do
          @list = lists(:music_songs_list)
          @list.update!(wizard_state: nil)
        end

        # ============================================
        # Factory Method Tests
        # ============================================

        test ".for returns Songs::StateManager for Music::Songs::List" do
          manager = StateManager.for(@list)
          assert_instance_of Services::Lists::Wizard::Music::Songs::StateManager, manager
        end

        test ".for returns base StateManager for Music::Albums::List" do
          album_list = lists(:music_albums_list)
          manager = StateManager.for(album_list)
          assert_instance_of Services::Lists::Wizard::StateManager, manager
        end

        test ".for returns base StateManager for Books::List" do
          books_list = lists(:books_list)
          manager = StateManager.for(books_list)
          assert_instance_of Services::Lists::Wizard::StateManager, manager
        end

        # ============================================
        # Current Step Tests
        # ============================================

        test "#current_step returns 0 when wizard_state is nil" do
          manager = StateManager.for(@list)
          assert_equal 0, manager.current_step
        end

        test "#current_step returns 0 when wizard_state is empty" do
          @list.update!(wizard_state: {})
          manager = StateManager.for(@list)
          assert_equal 0, manager.current_step
        end

        test "#current_step returns stored value" do
          @list.update!(wizard_state: {"current_step" => 3})
          manager = StateManager.for(@list)
          assert_equal 3, manager.current_step
        end

        test "#current_step_name returns step name from index" do
          @list.update!(wizard_state: {"current_step" => 0})
          manager = StateManager.for(@list)
          assert_equal "source", manager.current_step_name

          @list.update!(wizard_state: {"current_step" => 1})
          manager = StateManager.for(@list)
          assert_equal "parse", manager.current_step_name

          @list.update!(wizard_state: {"current_step" => 2})
          manager = StateManager.for(@list)
          assert_equal "enrich", manager.current_step_name
        end

        test "#current_step_name returns source for invalid index" do
          @list.update!(wizard_state: {"current_step" => 999})
          manager = StateManager.for(@list)
          assert_equal "source", manager.current_step_name
        end

        # ============================================
        # Step Status Tests
        # ============================================

        test "#step_status returns idle by default for unknown step" do
          @list.update!(wizard_state: {})
          manager = StateManager.for(@list)
          assert_equal "idle", manager.step_status("parse")
        end

        test "#step_status returns stored value for step" do
          @list.update!(wizard_state: {
            "steps" => {
              "parse" => {"status" => "completed", "progress" => 100}
            }
          })
          manager = StateManager.for(@list)
          assert_equal "completed", manager.step_status("parse")
          assert_equal "idle", manager.step_status("enrich")
        end

        # ============================================
        # Step Progress Tests
        # ============================================

        test "#step_progress returns 0 by default" do
          @list.update!(wizard_state: {})
          manager = StateManager.for(@list)
          assert_equal 0, manager.step_progress("parse")
        end

        test "#step_progress returns stored value for step" do
          @list.update!(wizard_state: {
            "steps" => {
              "parse" => {"status" => "running", "progress" => 75}
            }
          })
          manager = StateManager.for(@list)
          assert_equal 75, manager.step_progress("parse")
        end

        # ============================================
        # Step Error Tests
        # ============================================

        test "#step_error returns nil by default" do
          @list.update!(wizard_state: {})
          manager = StateManager.for(@list)
          assert_nil manager.step_error("parse")
        end

        test "#step_error returns stored value for step" do
          @list.update!(wizard_state: {
            "steps" => {
              "parse" => {"status" => "failed", "error" => "Something went wrong"}
            }
          })
          manager = StateManager.for(@list)
          assert_equal "Something went wrong", manager.step_error("parse")
        end

        # ============================================
        # Step Metadata Tests
        # ============================================

        test "#step_metadata returns empty hash by default" do
          @list.update!(wizard_state: {})
          manager = StateManager.for(@list)
          assert_equal({}, manager.step_metadata("parse"))
        end

        test "#step_metadata returns stored value for step" do
          @list.update!(wizard_state: {
            "steps" => {
              "parse" => {"status" => "completed", "metadata" => {"total_items" => 50}}
            }
          })
          manager = StateManager.for(@list)
          assert_equal({"total_items" => 50}, manager.step_metadata("parse"))
        end

        # ============================================
        # Update Step Status Tests
        # ============================================

        test "#update_step_status! creates step data" do
          @list.update!(wizard_state: {})
          manager = StateManager.for(@list)

          manager.update_step_status!(
            step: "parse",
            status: "running",
            progress: 50,
            metadata: {total_items: 100}
          )

          @list.reload
          assert_equal "running", manager.step_status("parse")
          assert_equal 50, manager.step_progress("parse")
          assert_equal({"total_items" => 100}, manager.step_metadata("parse"))
        end

        test "#update_step_status! preserves other steps" do
          @list.update!(wizard_state: {
            "steps" => {
              "parse" => {"status" => "completed", "progress" => 100, "error" => nil, "metadata" => {"total_items" => 50}}
            }
          })
          manager = StateManager.for(@list)

          manager.update_step_status!(
            step: "enrich",
            status: "running",
            progress: 25
          )

          @list.reload
          # Parse step should be unchanged
          assert_equal "completed", manager.step_status("parse")
          assert_equal 100, manager.step_progress("parse")

          # Enrich step should be updated
          assert_equal "running", manager.step_status("enrich")
          assert_equal 25, manager.step_progress("enrich")
        end

        test "#update_step_status! merges metadata" do
          @list.update!(wizard_state: {
            "steps" => {
              "enrich" => {"status" => "running", "progress" => 50, "metadata" => {"total_items" => 100}}
            }
          })
          manager = StateManager.for(@list)

          manager.update_step_status!(
            step: "enrich",
            status: "running",
            progress: 75,
            metadata: {processed_items: 75}
          )

          @list.reload
          expected = {"total_items" => 100, "processed_items" => 75}
          assert_equal expected, manager.step_metadata("enrich")
        end

        test "#update_step_status! preserves progress if not provided" do
          @list.update!(wizard_state: {
            "steps" => {"parse" => {"progress" => 30}}
          })
          manager = StateManager.for(@list)

          manager.update_step_status!(step: "parse", status: "running")

          @list.reload
          assert_equal 30, manager.step_progress("parse")
        end

        # ============================================
        # Reset Step Tests
        # ============================================

        test "#reset_step! resets only that step" do
          @list.update!(wizard_state: {
            "steps" => {
              "parse" => {"status" => "completed", "progress" => 100, "error" => nil, "metadata" => {"total_items" => 50}},
              "enrich" => {"status" => "completed", "progress" => 100, "error" => nil, "metadata" => {"processed_items" => 50}}
            }
          })
          manager = StateManager.for(@list)

          manager.reset_step!("parse")

          @list.reload
          # Parse should be reset
          assert_equal "idle", manager.step_status("parse")
          assert_equal 0, manager.step_progress("parse")
          assert_nil manager.step_error("parse")
          assert_equal({}, manager.step_metadata("parse"))

          # Enrich should be unchanged
          assert_equal "completed", manager.step_status("enrich")
          assert_equal 100, manager.step_progress("enrich")
        end

        # ============================================
        # Reset Wizard Tests
        # ============================================

        test "#reset! sets all initial values" do
          @list.update!(wizard_state: {
            "current_step" => 5,
            "started_at" => 1.hour.ago.iso8601,
            "steps" => {"parse" => {"status" => "completed"}}
          })
          manager = StateManager.for(@list)

          manager.reset!

          @list.reload
          assert_equal 0, manager.current_step
          assert_equal "idle", manager.step_status("parse")
          assert_equal({}, @list.wizard_state["steps"])
          assert @list.wizard_state["started_at"].present?
          assert_nil @list.wizard_state["completed_at"]
        end

        # ============================================
        # In Progress Tests
        # ============================================

        test "#in_progress? returns false when wizard_state is nil" do
          manager = StateManager.for(@list)
          assert_not manager.in_progress?
        end

        test "#in_progress? returns false when not started" do
          @list.update!(wizard_state: {})
          manager = StateManager.for(@list)
          assert_not manager.in_progress?
        end

        test "#in_progress? returns true when started but not completed" do
          @list.update!(wizard_state: {"started_at" => Time.current.iso8601})
          manager = StateManager.for(@list)
          assert manager.in_progress?
        end

        test "#in_progress? returns false when completed" do
          @list.update!(wizard_state: {
            "started_at" => 1.hour.ago.iso8601,
            "completed_at" => Time.current.iso8601
          })
          manager = StateManager.for(@list)
          assert_not manager.in_progress?
        end

        # ============================================
        # Steps Method Tests
        # ============================================

        test "#steps returns default wizard steps for base class" do
          books_list = lists(:books_list)
          manager = StateManager.for(books_list)
          assert_equal %w[source parse enrich validate review import complete], manager.steps
        end

        # ============================================
        # Step Status Persistence Tests
        # ============================================

        test "step status persists when navigating forward" do
          @list.update!(wizard_state: {
            "current_step" => 1,
            "steps" => {
              "parse" => {"status" => "completed", "progress" => 100, "error" => nil, "metadata" => {"total_items" => 50}}
            }
          })
          StateManager.for(@list)

          # Simulate advancing to enrich step (just update current_step, preserve status)
          @list.update!(wizard_state: @list.wizard_state.merge("current_step" => 2))

          @list.reload
          manager = StateManager.for(@list)
          # Parse status should still be completed
          assert_equal "completed", manager.step_status("parse")
          assert_equal 100, manager.step_progress("parse")

          # Enrich status should be idle (not started yet)
          assert_equal "idle", manager.step_status("enrich")
        end

        test "step status persists when navigating back" do
          @list.update!(wizard_state: {
            "current_step" => 2,
            "steps" => {
              "parse" => {"status" => "completed", "progress" => 100, "error" => nil, "metadata" => {"total_items" => 50}},
              "enrich" => {"status" => "completed", "progress" => 100, "error" => nil, "metadata" => {"processed_items" => 50}}
            }
          })

          # Simulate going back to parse step
          @list.update!(wizard_state: @list.wizard_state.merge("current_step" => 1))

          @list.reload
          manager = StateManager.for(@list)
          # Both steps should retain their status
          assert_equal "completed", manager.step_status("parse")
          assert_equal "completed", manager.step_status("enrich")
        end
      end
    end
  end
end
