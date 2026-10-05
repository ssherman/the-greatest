require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      module Apply
        class MergeAuthorsTest < ActiveSupport::TestCase
          setup do
            @source = ::Books::Author.create!(name: "Ann Example")
            @target = ::Books::Author.create!(name: "Ann  Example")
          end

          def verdict(source_id: @source.id, target_id: @target.id)
            ::Books::RepairVerdict.create!(kind: :merge_authors, subject_key: "authors:#{source_id}:#{target_id}",
              decided_by: :ai, status: :approved, payload: {"source_id" => source_id, "target_id" => target_id})
          end

          test "merges the source into the target through the author merger" do
            ::Books::Author::Merger.expects(:call).with(source: @source, target: @target)
              .returns(::Books::Author::Merger::Result.new(success?: true, data: @target, errors: []))

            assert_equal :applied, MergeAuthors.call(verdict: verdict).data[:outcome]
          end

          test "a source already merged away is a no-op" do
            ::Books::Author::Merger.expects(:call).never

            result = MergeAuthors.call(verdict: verdict(source_id: 0))

            assert_equal :noop, result.data[:outcome]
            assert_equal "author 0 no longer exists", result.data[:reason]
          end

          test "a merger failure raises with its errors" do
            ::Books::Author::Merger.stubs(:call).returns(::Books::Author::Merger::Result.new(success?: false, data: nil, errors: ["nope"]))

            error = assert_raises(Failed) { MergeAuthors.call(verdict: verdict) }
            assert_equal "nope", error.message
          end
        end
      end
    end
  end
end
