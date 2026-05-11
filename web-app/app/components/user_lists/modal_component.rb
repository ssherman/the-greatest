module UserLists
  # Singleton modal rendered once per page in domain layouts.
  # The user-list-modal Stimulus controller listens for "user-list-modal:open"
  # events and fills the modal from the cached state.
  class ModalComponent < ViewComponent::Base
  end
end
