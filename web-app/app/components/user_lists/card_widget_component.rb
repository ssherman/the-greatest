module UserLists
  # Renders the per-card "Add to list" widget shell. The HTML is identical for
  # every visitor (cacheable at CloudFlare); the Stimulus controller fills in the
  # icon strip and label client-side from the bulk state in localStorage.
  #
  # Pluralized namespace because `UserList` is a model class (not a module).
  class CardWidgetComponent < ViewComponent::Base
    def initialize(listable:, label: "Add to list")
      @listable = listable
      @label = label
    end

    private

    attr_reader :listable, :label

    def listable_type
      listable.class.name
    end

    def listable_id
      listable.id
    end

    # Optional human title for the modal header (the JS reads it via data-title).
    def listable_title
      if listable.respond_to?(:title)
        listable.title
      elsif listable.respond_to?(:name)
        listable.name
      else
        listable.to_s
      end
    end
  end
end
