require "test_helper"

module Services
  module Books
    module GenrePlan
      class DraftTest < ActiveSupport::TestCase
        test "writes the drafted lists, the fixed audiences and an empty decisions map" do
          path = Rails.root.join("tmp", "draft_test_#{SecureRandom.hex(4)}.yml")
          response = Services::Ai::Result.new(success: true, data: {genres: [{name: "Fiction", definition: "x"}], notes: ["n"]})
          Services::Ai::Tasks::Books::GenreDraftTask.any_instance.stubs(:call).returns(response)

          result = Draft.call(path: path)

          plan = PlanFile.load(path)
          assert result.success?
          assert_equal ["n"], result.data[:notes]
          assert_equal ["Fiction"], plan.genre_names
          assert_equal PlanFile::AUDIENCES.keys, plan.audience_names
          assert_empty plan.decisions
          assert_match(/\Agenres-\d{4}-\d{2}\z/, plan.run)
        ensure
          FileUtils.rm_f(path)
        end

        test "refuses to overwrite a plan with decisions unless forced" do
          path = Rails.root.join("tmp", "draft_test_#{SecureRandom.hex(4)}.yml")
          PlanFile.new({"run" => "g", "decisions" => {1 => {"name" => "x", "action" => "keep"}}}, path: path).write
          Services::Ai::Tasks::Books::GenreDraftTask.any_instance.expects(:call).never

          refute Draft.call(path: path).success?
        ensure
          FileUtils.rm_f(path)
        end

        test "a failed AI call writes nothing" do
          path = Rails.root.join("tmp", "draft_test_#{SecureRandom.hex(4)}.yml")
          Services::Ai::Tasks::Books::GenreDraftTask.any_instance.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "bad"))

          result = Draft.call(path: path)

          refute result.success?
          assert_equal ["bad"], result.errors
          refute path.exist?
        ensure
          FileUtils.rm_f(path)
        end
      end
    end
  end
end
