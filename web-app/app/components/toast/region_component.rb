module Toast
  # Singleton toast region. The toast Stimulus controller listens on window for
  # "toast:show" events and appends transient alerts here.
  class RegionComponent < ViewComponent::Base
  end
end
