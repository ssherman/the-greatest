require "test_helper"

module Services
  module Descriptions
    class AdminWriteTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:war_and_peace)
        @ai = descriptions(:war_and_peace_ai)
        @wikipedia = descriptions(:war_and_peace_wikipedia)
      end

      test "create forces summary, en and normal and ignores any other kind, locale or rank" do
        @book.descriptions.destroy_all

        result = AdminWrite.create(describable: @book, attrs: {content: "Hello", source: "manual", kind: "long", locale: "fr", rank: "preferred"})

        assert result.success?
        description = result.data[:description]
        assert_equal ["summary", "en", "normal", "Hello"], [description.kind, description.locale, description.rank, description.content]
        assert description.persisted?
      end

      test "create with invalid data fails with :invalid and the validation messages" do
        result = AdminWrite.create(describable: @book, attrs: {content: "", source: "manual"})

        refute result.success?
        assert_equal :invalid, result.data[:code]
        assert_includes result.errors.join, "Content"
      end

      test "create refuses a second description with the same source, naming the existing one" do
        assert_no_difference "Description.count" do
          result = AdminWrite.create(describable: @book, attrs: {content: "Another", source: "ai_generated"})

          refute result.success?
          assert_equal :conflict, result.data[:code]
          assert_equal @ai.id, result.data[:existing_id]
        end
      end

      test "an :other source is unique per source_name" do
        assert AdminWrite.create(describable: @book, attrs: {content: "A", source: "other", source_name: "Penguin"}).success?

        same = AdminWrite.create(describable: @book, attrs: {content: "B", source: "other", source_name: "Penguin"})
        different = AdminWrite.create(describable: @book, attrs: {content: "C", source: "other", source_name: "Folio"})

        assert_equal :conflict, same.data[:code]
        assert different.success?
      end

      test "a lost race past the uniqueness validation is a conflict naming the winner" do
        Description.any_instance.stubs(:save).raises(ActiveRecord::RecordNotUnique)

        result = AdminWrite.create(describable: @book, attrs: {content: "Another", source: "ai_generated"})

        refute result.success?
        assert_equal :conflict, result.data[:code]
        assert_equal @ai.id, result.data[:existing_id]
      end

      test "update changes the permitted fields" do
        result = AdminWrite.update(description: @ai, attrs: {content: "Rewritten"})

        assert result.success?
        assert_equal "Rewritten", @ai.reload.content
      end

      test "update to a source another description holds is a conflict naming it" do
        result = AdminWrite.update(description: @ai, attrs: {source: "wikipedia"})

        refute result.success?
        assert_equal :conflict, result.data[:code]
        assert_equal @wikipedia.id, result.data[:existing_id]
        assert_equal "ai_generated", @ai.reload.source
      end

      test "update with blank content fails with :invalid" do
        result = AdminWrite.update(description: @ai, attrs: {content: ""})

        refute result.success?
        assert_equal :invalid, result.data[:code]
      end

      test "destroy removes the description" do
        result = AdminWrite.destroy(description: @ai)

        assert result.success?
        refute Description.exists?(@ai.id)
      end

      test "set_preferred leaves exactly one preferred description for the key" do
        @ai.update!(rank: :preferred)

        result = AdminWrite.set_preferred(description: @wikipedia)

        assert result.success?
        assert_equal ["normal", "preferred"], [@ai.reload.rank, @wikipedia.reload.rank]
        assert_equal 1, @book.descriptions.where(kind: :summary, locale: "en", rank: :preferred).count
      end

      test "set_preferred on an already preferred description keeps it preferred" do
        @wikipedia.update!(rank: :preferred)

        assert AdminWrite.set_preferred(description: @wikipedia).success?
        assert_equal "preferred", @wikipedia.reload.rank
      end

      test "set_preferred leaves other kinds alone" do
        other_kind = @book.descriptions.create!(kind: :long, locale: "en", source: :manual, content: "Long", rank: :preferred)

        AdminWrite.set_preferred(description: @wikipedia)

        assert_equal "preferred", other_kind.reload.rank
      end
    end
  end
end
