require "test_helper"

module Categories
  class EditorTest < ActiveSupport::TestCase
    setup do
      Sidekiq::Worker.clear_all
    end

    def jobs = ::Categories::ReconcileAncestorsJob.jobs.size

    test "reparenting a location enqueues the reconcile" do
      france = categories(:books_france_location)
      parent = categories(:books_american_location)

      Sidekiq::Testing.fake! do
        result = Editor.call(category: france, attributes: {parent_id: parent.id})

        assert result.success?, result.errors.join(", ")
        assert_equal france, result.data
        assert_equal 1, jobs
      end
    end

    test "retyping a location away enqueues the reconcile" do
      Sidekiq::Testing.fake! do
        result = Editor.call(category: categories(:books_france_location), attributes: {category_type: "subject"})

        assert result.success?, result.errors.join(", ")
        assert_equal 1, jobs
      end
    end

    test "renaming a genre does not enqueue the reconcile" do
      Sidekiq::Testing.fake! do
        result = Editor.call(category: categories(:books_novels_genre), attributes: {name: "Novels, Long"})

        assert result.success?
        assert_equal 0, jobs
      end
    end

    test "a rename keeps the id and the old slug still resolves" do
      category = Editor.call(category: ::Books::Category.new, attributes: {name: "Old Name", category_type: "genre"}).data
      old_slug = category.slug

      result = Editor.call(category: category, attributes: {name: "Fresh Name"})

      assert result.success?
      assert_not_equal old_slug, category.reload.slug
      assert_equal category, ::Books::CategorySlugResolver.call(old_slug)
    end

    test "creates a new record" do
      Sidekiq::Testing.fake! do
        result = Editor.call(category: ::Books::Category.new, attributes: {name: "Brand New", category_type: "theme"})

        assert result.success?
        assert result.data.persisted?
        assert_equal 0, jobs
      end
    end

    test "a failed save reports the model's messages and enqueues nothing" do
      novels = categories(:books_novels_genre)

      Sidekiq::Testing.fake! do
        result = Editor.call(category: novels, attributes: {parent_id: novels.id})

        assert_not result.success?
        assert_includes result.errors.join, "itself"
        assert_equal 0, jobs
      end
    end
  end
end
