class Avo::Resources::MusicAlbumsList < Avo::Resources::List
  self.model_class = ::Music::Albums::List
end
