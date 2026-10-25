# Base class for a workflow definition: a name, a version, the class of record
# it runs against and an ordered list of steps. Subclasses declare these at
# class level; bump `version` when the step set changes so in-flight runs keep
# the shape they were planned with.
module Workflows
  class Definition
    class << self
      def workflow(name = nil)
        @workflow = name if name
        @workflow or raise NotImplementedError, "#{self} must declare a workflow name"
      end

      def version(number = nil)
        @version = number if number
        @version || 1
      end

      def target_class(klass = nil)
        @target_class = klass if klass
        @target_class or raise NotImplementedError, "#{self} must declare a target_class"
      end

      def steps
        @steps ||= []
      end

      # Declares a step; arguments are those of Workflows::Step.build.
      # A repeated key would make `step(key)` silently return the first one.
      def add_step(**attributes)
        step = Workflows::Step.build(**attributes)
        raise ArgumentError, "duplicate step key #{step.key} in #{self}" if step(step.key)
        steps << step
      end

      # Checks the whole step set once it is complete. A waits_on key is matched
      # against every declared key, not only earlier ones, so it cannot run in
      # add_step; a typo there would leave the step waiting forever.
      def validate!
        keys = steps.map(&:key)
        steps.each do |step|
          unknown = step.waits_on.keys.map(&:to_sym) - keys
          next if unknown.empty?
          raise ArgumentError, "step #{step.key} in #{self} waits on unknown step #{unknown.first}"
        end
        self
      end

      # The declared step with this key, or nil.
      def step(key)
        steps.find { |step| step.key == key.to_sym }
      end
    end
  end
end
