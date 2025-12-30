# frozen_string_literal: true

# Albums-specific modal component that inherits from the shared base.
# All functionality is provided by Admin::Music::Wizard::SharedModalComponent.
#
# This subclass exists to maintain the domain-specific namespace for constants:
#   Admin::Music::Albums::Wizard::SharedModalComponent::FRAME_ID
#   Admin::Music::Albums::Wizard::SharedModalComponent::DIALOG_ID
#   Admin::Music::Albums::Wizard::SharedModalComponent::ERROR_ID
#
# Usage:
#   <%= render(Admin::Music::Albums::Wizard::SharedModalComponent.new) %>
class Admin::Music::Albums::Wizard::SharedModalComponent < Admin::Music::Wizard::SharedModalComponent
end
