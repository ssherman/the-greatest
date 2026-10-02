# frozen_string_literal: true

require "test_helper"

# Every ERB template must at least compile. A template that cannot compile
# only fails when something renders it, so a rarely used one can sit broken
# indefinitely. layouts/application.html.erb did, until 2026-10. This compiles
# each template's generated Ruby without rendering it.
class ErbTemplatesCompileTest < ActiveSupport::TestCase
  TEMPLATES = Dir[Rails.root.join("app/{views,components}/**/*.erb")]

  test "every ERB template under app/views and app/components compiles" do
    # Guards against an empty glob passing vacuously.
    assert_operator TEMPLATES.size, :>, 100

    handler = ActionView::Template::Handlers::ERB.new
    failures = TEMPLATES.filter_map do |path|
      source = File.read(path)
      virtual_path = path.delete_prefix("#{Rails.root}/app/views/")
      template = ActionView::Template.new(source, path, handler, locals: [], format: :html, virtual_path: virtual_path)
      RubyVM::InstructionSequence.compile("def __erb_compile_check(local_assigns, output_buffer)\n#{handler.call(template, source)}\nend")
      nil
    rescue SyntaxError => e
      "#{Pathname(path).relative_path_from(Rails.root)}: #{e.message.lines.first.strip}"
    end

    assert_empty failures
  end
end
