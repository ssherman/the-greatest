require "test_helper"

class Admin::Categories::FormComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  def books_config
    {
      model_class: Books::Category,
      category_path_proc: ->(category) { admin_books_category_path(category) },
      categories_path: admin_books_categories_path,
      new_category_path: new_admin_books_category_path,
      edit_category_path_proc: ->(category) { edit_admin_books_category_path(category) },
      categories_search_path: search_admin_books_categories_path,
      domain_label: "Books",
      subtitle: "Manage book genres"
    }
  end

  def music_config
    {
      model_class: Music::Category,
      category_path_proc: ->(category) { admin_category_path(category) },
      categories_path: admin_categories_path,
      new_category_path: new_admin_category_path,
      edit_category_path_proc: ->(category) { edit_admin_category_path(category) },
      categories_search_path: search_admin_categories_path,
      domain_label: "Music",
      subtitle: "Manage music genres"
    }
  end

  test "the parent chooser is a typeahead against the domain's category search, never a select of every category" do
    render_inline(Admin::Categories::FormComponent.new(category: Books::Category.new, domain_config: books_config))

    assert_no_selector "select[name='books_category[parent_id]']"
    assert_selector "input[type=hidden][name='books_category[parent_id]']", visible: :all
    assert_selector "[data-controller=autocomplete][data-autocomplete-url-value='#{search_admin_books_categories_path}']"
  end

  test "editing a child preselects its parent by id and shows the parent's name" do
    child = categories(:music_progressive_rock_genre)
    parent = categories(:music_rock_genre)
    render_inline(Admin::Categories::FormComponent.new(category: child, domain_config: music_config))

    assert_selector "input[type=hidden][name='music_category[parent_id]'][value='#{parent.id}']", visible: :all
    assert_selector "input[type=search][value='#{parent.name_with_type}']"
  end

  test "a top-level category renders an empty parent" do
    render_inline(Admin::Categories::FormComponent.new(category: categories(:music_rock_genre), domain_config: music_config))

    assert_selector "input[type=hidden][name='music_category[parent_id]']:not([value]), input[type=hidden][name='music_category[parent_id]'][value='']", visible: :all
    assert_selector "input[type=search]:not([value]), input[type=search][value='']"
  end
end
