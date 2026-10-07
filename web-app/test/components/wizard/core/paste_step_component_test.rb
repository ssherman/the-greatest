# frozen_string_literal: true

require "test_helper"

class Wizard::Core::PasteStepComponentTest < ViewComponent::TestCase
  include ListWizardHelper

  test "the form posts the pasted content to save_content and shows what was pasted before" do
    list = wizard_list(raw_content: "1. Emma by Jane Austen")
    adapter = ::Services::Lists::Wizard::Books::Adapter.new

    render_inline(Wizard::Core::PasteStepComponent.new(list: list, adapter: adapter))

    assert_selector "form[action='#{adapter.wizard_path(:save_content, list)}'][method=post]"
    assert_selector "textarea[name=raw_content]#raw_content", text: "1. Emma by Jane Austen"
    assert_selector "label[for=raw_content]"
    assert_selector "input[type=checkbox][name=batch_mode][value='1']:not([checked])"
  end

  test "the large-list checkbox shows the list's batch mode" do
    list = wizard_list
    list.update!(wizard_state: {"batch_mode" => true})

    render_inline(Wizard::Core::PasteStepComponent.new(list: list, adapter: ::Services::Lists::Wizard::Books::Adapter.new))

    assert_selector "input[type=checkbox][name=batch_mode][value='1'][checked]"
  end
end
