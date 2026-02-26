module Admin
  module Music
    module Albums
      class ListsController < Admin::Music::ListsController
        protected

        def list_class
          ::Music::Albums::List
        end

        def lists_path
          admin_albums_lists_path
        end

        def list_path(list)
          admin_albums_list_path(list)
        end

        def new_list_path
          new_admin_albums_list_path
        end

        def edit_list_path(list)
          edit_admin_albums_list_path(list)
        end

        def param_key
          :music_albums_list
        end

        def items_count_name
          "albums_count"
        end

        def listable_includes
          [:artists, :categories, :primary_image]
        end

        def wizard_path(list)
          admin_albums_list_wizard_path(list_id: list.id)
        end
      end
    end
  end
end
