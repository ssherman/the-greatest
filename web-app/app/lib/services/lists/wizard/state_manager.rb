# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      # Base class for wizard state management.
      # Provides a consistent interface for reading and updating wizard state
      # stored in a List's wizard_state JSONB column.
      #
      # == Usage
      #
      #   manager = Services::Lists::Wizard::StateManager.for(list)
      #   manager.current_step_name # => "parse"
      #   manager.step_status("parse") # => "running"
      #   manager.update_step_status!(step: "parse", status: "completed", progress: 100)
      #
      # == Subclassing
      #
      # Domain-specific subclasses should override the #steps method to define
      # their wizard steps:
      #
      #   class Music::Songs::StateManager < StateManager
      #     def steps
      #       %w[source parse enrich validate review import complete]
      #     end
      #   end
      #
      class StateManager
        attr_reader :list

        # Factory method to return the appropriate StateManager subclass
        # based on the list's type.
        #
        # @param list [List] the list instance
        # @return [StateManager] an instance of the appropriate subclass
        def self.for(list)
          manager_class = case list.type
          when "Music::Songs::List"
            Services::Lists::Wizard::Music::Songs::StateManager
          when "Music::Albums::List"
            # Future: Music::Albums::StateManager
            self
          else
            self
          end

          manager_class.new(list)
        end

        # @param list [List] the list instance with wizard_state column
        def initialize(list)
          @list = list
        end

        # Returns the ordered array of step names for this wizard.
        # Override in subclasses to define domain-specific steps.
        #
        # @return [Array<String>] step names in order
        def steps
          %w[source parse enrich validate review import complete]
        end

        # Returns the current step index from wizard_state.
        #
        # @return [Integer] zero-based step index
        def current_step
          safe_wizard_state.fetch("current_step", 0)
        end

        # Returns the name of the current step.
        #
        # @return [String] step name (e.g., "parse", "enrich")
        def current_step_name
          steps[current_step] || steps.first
        end

        # Returns the status of a specific step.
        #
        # @param step_name [String] the step to query
        # @return [String] status: "idle", "running", "completed", or "failed"
        def step_status(step_name)
          step_data(step_name).fetch("status", "idle")
        end

        # Returns the progress percentage of a specific step.
        #
        # @param step_name [String] the step to query
        # @return [Integer] progress from 0-100
        def step_progress(step_name)
          step_data(step_name).fetch("progress", 0)
        end

        # Returns the error message for a specific step, if any.
        #
        # @param step_name [String] the step to query
        # @return [String, nil] error message or nil
        def step_error(step_name)
          step_data(step_name).fetch("error", nil)
        end

        # Returns the metadata hash for a specific step.
        #
        # @param step_name [String] the step to query
        # @return [Hash] step-specific metadata
        def step_metadata(step_name)
          step_data(step_name).fetch("metadata", {})
        end

        # Updates the status of a specific step.
        # Merges metadata with existing metadata (does not replace).
        #
        # @param step [String] the step to update
        # @param status [String] new status ("idle", "running", "completed", "failed")
        # @param progress [Integer, nil] progress percentage (0-100)
        # @param error [String, nil] error message
        # @param metadata [Hash] additional metadata to merge
        # @return [Boolean] true if update succeeded
        def update_step_status!(step:, status:, progress: nil, error: nil, metadata: {})
          step_key = step.to_s
          current_step_state = step_data(step_key)

          new_step_state = {
            "status" => status,
            "progress" => progress || current_step_state.fetch("progress", 0),
            "error" => error,
            "metadata" => current_step_state.fetch("metadata", {}).merge(metadata.stringify_keys)
          }

          steps_data = wizard_steps_data.merge(step_key => new_step_state)
          new_state = safe_wizard_state.merge("steps" => steps_data)

          list.update!(wizard_state: new_state)
        end

        # Resets a single step to its initial state.
        #
        # @param step_name [String] the step to reset
        # @return [Boolean] true if reset succeeded
        def reset_step!(step_name)
          step_key = step_name.to_s
          steps_data = wizard_steps_data.merge(step_key => default_step_state)
          new_state = safe_wizard_state.merge("steps" => steps_data)

          list.update!(wizard_state: new_state)
        end

        # Resets the entire wizard to its initial state.
        #
        # @return [Boolean] true if reset succeeded
        def reset!
          list.update!(wizard_state: {
            "current_step" => 0,
            "started_at" => Time.current.iso8601,
            "completed_at" => nil,
            "steps" => {}
          })
        end

        # Checks if the wizard is currently in progress.
        #
        # @return [Boolean] true if started but not completed
        def in_progress?
          safe_wizard_state.fetch("started_at", nil).present? &&
            safe_wizard_state.fetch("completed_at", nil).nil?
        end

        private

        def safe_wizard_state
          list.wizard_state || {}
        end

        def wizard_steps_data
          safe_wizard_state.fetch("steps", {})
        end

        def step_data(step_name)
          wizard_steps_data.fetch(step_name.to_s, default_step_state)
        end

        def default_step_state
          {"status" => "idle", "progress" => 0, "error" => nil, "metadata" => {}}
        end
      end
    end
  end
end
