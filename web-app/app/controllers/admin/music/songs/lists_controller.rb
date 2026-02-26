module Admin
  module Music
    module Songs
      class ListsController < Admin::Music::ListsController
        protected

        def list_class
          ::Music::Songs::List
        end

        def lists_path
          admin_songs_lists_path
        end

        def list_path(list)
          admin_songs_list_path(list)
        end

        def new_list_path
          new_admin_songs_list_path
        end

        def edit_list_path(list)
          edit_admin_songs_list_path(list)
        end

        def param_key
          :music_songs_list
        end

        def items_count_name
          "songs_count"
        end

        def listable_includes
          [:artists]
        end

        def item_label
          "Song"
        end

        def wizard_path(list)
          admin_songs_list_wizard_path(list_id: list.id)
        end
      end
    end
  end
end
