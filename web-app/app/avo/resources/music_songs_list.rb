class Avo::Resources::MusicSongsList < Avo::Resources::List
  self.model_class = ::Music::Songs::List
end
