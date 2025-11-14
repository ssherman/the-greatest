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
      end
    end
  end
end
