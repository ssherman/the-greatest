# frozen_string_literal: true

# Songs-specific modal component that inherits from the shared base.
# All functionality is provided by Admin::Music::Wizard::SharedModalComponent.
#
# This subclass exists to maintain the domain-specific namespace for constants:
#   Admin::Music::Songs::Wizard::SharedModalComponent::FRAME_ID
#   Admin::Music::Songs::Wizard::SharedModalComponent::DIALOG_ID
#   Admin::Music::Songs::Wizard::SharedModalComponent::ERROR_ID
#
# Usage:
#   <%= render(Admin::Music::Songs::Wizard::SharedModalComponent.new) %>
class Admin::Music::Songs::Wizard::SharedModalComponent < Admin::Music::Wizard::SharedModalComponent
end
