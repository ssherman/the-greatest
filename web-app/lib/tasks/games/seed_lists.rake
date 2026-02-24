# frozen_string_literal: true

namespace :games do
  desc "Seed game-specific lists (best-of-all-time lists from various publications). Idempotent - skips existing lists."
  task seed_lists: :environment do
    lists_data = [
      { year: 2025, source: "Dexerto", name: "These are the 100 best games of all time", url: "https://www.dexerto.com/gaming/best-games-all-time-2855973/" },
      { year: 2025, source: "Indy100", name: "The best 100 video games of all time", url: "https://www.indy100.com/gaming/best-video-games-ever-all-time-100-81" },
      { year: 2025, source: "Multiplayer.it", name: "I 100 migliori videogiochi della storia", url: "https://multiplayer.it/articoli/i-100-migliori-videogiochi-della-storia.html" },
      { year: 2025, source: "Rolling Stone", name: "The 50 Greatest Video Games of All Time", url: "https://www.rollingstone.com/culture/rs-gaming-lists/best-video-games-of-all-time-1235215978/" },
      { year: 2024, source: "Dexerto", name: "These are the 100 best games of all time", url: "https://www.dexerto.com/gaming/best-games-all-time-2855973/" },
      { year: 2024, source: "Moustique", name: "On a classé les 100 meilleurs jeux vidéo depuis la sortie de Pong en 1972 (pour fêter les 100 ans de Moustique)", url: "https://www.moustique.be/culture/2024/11/02/on-a-classe-les-100-meilleurs-jeux-video-depuis-la-sortie-de-pong-en-1972-pour-feter-les-100-ans-de-moustique-JH7WZ3VXJZEYNCWWPS6P5MEGPE/" },
      { year: 2024, source: "Screen Rant", name: "Screen Rant's Best Games Of All Time", url: "https://screenrant.com/best-video-games-all-time-ranked/" },
      { year: 2023, source: "British GQ", name: "The 100 greatest video games of all time, ranked by experts", url: "https://www.gq-magazine.co.uk/article/best-video-games-all-time" },
      { year: 2023, source: "Digital Trends", name: "The 50 best video games of all time", url: "https://www.digitaltrends.com/gaming/50-best-games-of-all-time/" },
      { year: 2023, source: "GameStar", name: "Die 300 besten PC-Spiele: Das große Ranking", url: "https://www.gamestar.de/artikel/300-beste-pc-spiele,3388068.html" },
      { year: 2023, source: "GLHF", name: "The best 100 games of all time, ranked", url: "https://videogames.si.com/guides/best-games" },
      { year: 2023, source: "Parade", name: "We Ranked the 25 Best Video Games of All Time", url: "https://parade.com/entertainment/best-video-games-of-all-time" },
      { year: 2023, source: "The Times", name: "20 best video games of all time — ranked by an expert jury", url: "https://www.thetimes.co.uk/article/20-best-video-games-of-all-time-ranked-by-an-expert-jury-l5zgrxmw8" },
      { year: 2022, source: "Gamereactor", name: "Best Ever: Spel", url: "https://www.gamereactor.se/best-ever-spel-101-1066613/%7C" },
      { year: 2022, source: "GLHF", name: "The 100 best video games of all time, ranked", url: "https://ftw.usatoday.com/lists/best-video-games" },
      { year: 2022, source: "IGN", name: "The Top 100 Video Games of All Time", url: "https://www.ign.com/articles/the-best-100-video-games-of-all-time" },
      { year: 2021, source: "GamesRadar+", name: "The 50 best games of all time", url: "https://www.gamesradar.com/best-games-of-all-time/" },
      { year: 2020, source: "Collider", name: "The Greatest and Most Influential Video Games of All Time", url: "https://web.archive.org/web/20201025213541/https://collider.com/galleries/greatest-video-games-of-all-time/" },
      { year: 2020, source: "Esquire", name: "The 15 Best Video Games of All Time, Ranked", url: "https://www.esquire.com/lifestyle/g26572573/best-video-games-ranked/" },
      { year: 2020, source: "GAMINGbible", name: "The Greatest Video Games Of All Time", url: "https://web.archive.org/web/20211019140731/https://www.gamingbible.co.uk/features/games-the-greatest-video-games-of-all-time-100-81-20201130" },
      { year: 2020, source: "GQ Spain", name: "Los 100 mejores videojuegos de la historia", url: "https://www.revistagq.com/noticias/tecnologia/galerias/los-100-mejores-videojuegos-de-la-historia/8951" },
      { year: 2020, source: "Hardcore Gaming 101", name: "HG101 Presents: The 200 Best Video Games of All Time", url: "http://www.hardcoregaming101.net/books/hg101-presents-the-200-best-video-games-of-all-time/" },
      { year: 2020, source: "Mashable", name: "What are the best video games of all time? I asked our team to help decide.", url: "https://mashable.com/article/best-video-games-of-all-time" },
      { year: 2020, source: "Slant Magazine", name: "The 100 Best Video Games of All Time", url: "https://www.slantmagazine.com/games/the-100-best-video-games-of-all-time/" },
      { year: 2019, source: "IGN", name: "Top 100 Video Games of All Time", url: "https://www.ign.com/lists/top-100-games" },
      { year: 2019, source: "Popular Mechanics", name: "The 100 Greatest Video Games of All Time", url: "https://www.popularmechanics.com/culture/gaming/g134/the-100-greatest-video-games-of-all-time/" },
      { year: 2018, source: "Esquire", name: "The (Real) Greatest Video Games of All-Time", url: "https://web.archive.org/web/20181107001605/https://www.esquire.com/uk/culture/a24173497/the-greatest-video-games-of-all-time/" },
      { year: 2018, source: "Game Informer", name: "The Top 300 Games of All Time", url: "https://archive.gamehistory.org/item/39a2674e-8ace-41d1-8ab1-fd4f48c68019" },
      { year: 2018, source: "GameStar", name: "Die 250 besten PC-Spiele aller Zeiten - Das große GameStar-Ranking", url: "https://web.archive.org/web/20181114001118/https://www.gamestar.de/artikel/die-250-besten-pc-spiele-aller-zeiten,3331911.html" },
      { year: 2018, source: "GamesTM", name: "The 200 Greatest Games of All Time", url: nil },
      { year: 2018, source: "Hyper", name: "The 200 Games You Must Play", url: nil },
      { year: 2018, source: "IGN", name: "Top 100 Video Games of All Time", url: "https://web.archive.org/web/20180628102927/http://www.ign.com/lists/top-100-games" },
      { year: 2018, source: "Slant Magazine", name: "The 100 Greatest Video Games of All Time", url: "https://web.archive.org/web/20190204225303/https://www.slantmagazine.com/features/the-100-greatest-video-games-of-all-time/" },
      { year: 2017, source: "Edge", name: "The 100 Greatest Videogames", url: nil },
      { year: 2017, source: "Gamereactor", name: "Gamereactor's Top 100 bedste spil nogensinde", url: "https://www.gamereactor.dk/gamereactors-top-100-bedste-spil-nogensinde-101-438333/" },
      { year: 2017, source: "Jeuxvideo", name: "Top 100 des meilleurs jeux de tous les temps", url: "https://www.jeuxvideo.com/dossier/694881/top-100-des-meilleurs-jeux-de-tous-les-temps/" },
      { year: 2017, source: "Polygon", name: "The 500 best games of all time", url: "https://www.polygon.com/features/2017/11/27/16158276/polygon-500-best-games-of-all-time-500-401" },
      { year: 2017, source: "Stuff", name: "Stuff's Best Games Ever: The 50 greatest games of all time", url: "https://web.archive.org/web/20171015054923/https://www.stuff.tv/features/stuffs-best-games-ever-50-greatest-games-all-time" },
      { year: 2017, source: "TheWrap", name: "The 30 Best Video Games of All Time, Ranked", url: "https://www.thewrap.com/the-30-best-video-games-of-all-time-photos/" },
      { year: 2016, source: "Digitally Downloaded", name: "The top 100 of all time!", url: "https://www.digitallydownloaded.net/2016/09/the-top-100-of-all-time-how-many-have.html" },
      { year: 2016, source: "Gameswelt", name: "Gameswelt Top 100", url: "https://www.gameswelt.de/top-100/kampagne/gameswelt-top-100-260134" },
      { year: 2016, source: "Power Up Gaming", name: "The 100 Greatest Games Ever", url: "https://powerupgaming.co.uk/2016/06/04/the-100-greatest-games-ever-part-4-25-1/" },
      { year: 2016, source: "Time", name: "The 50 Best Video Games of All Time", url: "https://time.com/4458554/best-video-games-all-time/" },
      { year: 2015, source: "Edge", name: "The 100 Greatest Videogames", url: "https://archive.org/details/EDGE.the.100.greatest.videogames.2015/mode/2up" },
      { year: 2015, source: "GamesRadar+", name: "The 100 Best Games of All-Time", url: "https://web.archive.org/web/20150319223433/http://www.gamesradar.com/best-games-ever/" },
      { year: 2015, source: "GamesTM", name: "100 Greatest Games of All Time", url: "https://archive.org/details/GamesTM100GreatestGamesOfAllTime/mode/2up" },
      { year: 2015, source: "IGN", name: "Top 100 Games of All Time", url: "https://web.archive.org/web/20180201091940/http://www.ign.com/lists/top-100-games/100" },
      { year: 2015, source: "Power Unlimited", name: "Top 100 Beste Video Games Aller Tijden", url: "https://web.archive.org/web/20180316202451/https://www.pu.nl/artikelen/feature/top-100-games-aller-tijden/" },
      { year: 2014, source: "GamesRadar+", name: "The 100 best games of all time", url: "https://web.archive.org/web/20140321161256/http://gamesradar.com/best-games-ever/" },
      { year: 2014, source: "Popular Mechanics", name: "The 100 Greatest Video Games of All Time", url: "https://web.archive.org/web/20150905121049/http://www.popularmechanics.com/culture/gaming/g134/the-100-greatest-video-games-of-all-time/" },
      { year: 2014, source: "Slant Magazine", name: "100 Greatest Video Games of All Time", url: "https://web.archive.org/web/20150716193354/http://www.slantmagazine.com/features/article/100-greatest-video-games-of-all-time" },
      { year: 2014, source: "Stuff", name: "Best Games Ever: the 20 greatest games of all time", url: "https://web.archive.org/web/20160401100654/https://www.stuff.tv/my/features/best-games-ever-20-greatest-games-all-time" },
      { year: 2013, source: "EP Daily", name: "Top 100 Games & Movies Of All Time!", url: "https://www.youtube.com/playlist?list=PL6uoO3csitWN_KHRByq0eyPagW2z9FKYW" },
      { year: 2013, source: "GamesRadar+", name: "The 100 best games of all time", url: "https://web.archive.org/web/20140123082433/http://www.gamesradar.com/best-games-ever/" },
      { year: 2013, source: "GamingBolt", name: "Top 100 greatest video games ever made", url: "https://gamingbolt.com/top-100-greatest-video-games-ever-made" },
      { year: 2013, source: "NA", name: "1001 Video Games You Must Play Before You Die", url: nil },
      { year: 2013, source: "PC and Tech Authority", name: "100 games to play before you die", url: "https://web.archive.org/web/20131107131900/http://www.pcauthority.com.au/Feature/362415,100-games-to-play-before-you-die.aspx" },
      { year: 2013, source: "The Irish Times", name: "The 50 best videogames of all time", url: "https://www.irishtimes.com/culture/the-50-best-videogames-of-all-time-1.1610521" },
      { year: 2012, source: "Complex", name: "The 50 Best PC Games Of All Time", url: "https://web.archive.org/web/20121116014156/https://www.complex.com/video-games/2012/11/the-50-best-pc-games-of-all-time" },
      { year: 2012, source: "G4", name: "Top 100 Video Games of All Time", url: "https://web.archive.org/web/20121006174125/http://www.g4tv.com/top-100/" },
      { year: 2012, source: "GamesRadar+", name: "The 100 best games of all time", url: "https://web.archive.org/web/20120509195913/http://www.gamesradar.com/best-games-ever/" },
      { year: 2012, source: "Gameswelt", name: "Gameswelt Top 100", url: "https://www.gameswelt.de/gameswelttv/video/plaetze-81-100-165185" },
      { year: 2012, source: "Time", name: "All-TIME 100 Video Games", url: "https://techland.time.com/2012/11/15/all-time-100-video-games/" },
      { year: 2011, source: "Gamereactor", name: "Game Reactor top 100", url: "https://www.gamereactor.no/topp100/100/" },
      { year: 2011, source: "GamesRadar+", name: "The 100 best games of all time", url: "https://web.archive.org/web/20120118151554/http://www.gamesradar.com/the-100-best-games-of-all-time/" },
      { year: 2011, source: "Jeuxvideo", name: "Les 100 meilleurs jeux de tous les temps", url: "https://www.jeuxvideo.com/dossiers/00014196/les-100-meilleurs-jeux-de-tous-les-temps.htm" },
      { year: 2011, source: "Stuff", name: "Countdown of top 100 games", url: "https://web.archive.org/web/20111215115058/http://top100.stuff.tv/" },
      { year: 2010, source: "FHM", name: "FHM's 100 Greatest Games of All Time", url: "https://web.archive.org/web/20130430073137/http://www.fhm.com/reviews/console-games/fhms-100-greatest-games-of-all-time-20090901" },
      { year: 2010, source: "GamesTM", name: "100 Greatest Games Of All Time", url: "https://www.retromags.com/magazines/uk/games-tm/games-tm-issue-100/" },
      { year: 2010, source: "The Phoenix", name: "Top 50 Games of All Time", url: "https://web.archive.org/web/20130107220543/http://supplements.thephoenix.com/supplements/2010/50games/" },
      { year: 2009, source: "Benchmark.pl", name: "100 najlepszych gier XX wieku", url: "https://www.benchmark.pl/testy_i_recenzje/najlepsze-gry-20-wieku-cz-3-2643.html" },
      { year: 2009, source: "Edge", name: "The 100 Best Games To Play Today", url: "https://web.archive.org/web/20120325194117/http://www.edge-online.com/features/100-best-games-play-today" },
      { year: 2009, source: "Empire", name: "The 100 Greatest Games", url: "https://web.archive.org/web/20110706095032/http://www.empireonline.com/100greatestgames/default.asp?p=1" },
      { year: 2009, source: "Game Informer", name: "The Top 200 Games Of All Time", url: "https://archive.org/details/game-informer-issue-200-december-2009/mode/2up" },
      { year: 2009, source: "Jeux Video Network", name: "Les 100 meilleurs jeux vidéo de tous les temps", url: "https://web.archive.org/web/20100312043951/https://www.jvn.com/jeux/articles/les-100-meilleurs-jeux-de-tous-les-temps.html" },
      { year: 2008, source: "GamePro", name: "The 32 Best PC Games", url: "https://web.archive.org/web/20081102234825/http://www.gamepro.com/article/features/207295/the-32-best-pc-games/" },
      { year: 2008, source: "Stuff", name: "100 Greatest Games", url: nil },
      { year: 2007, source: "Computer and Video Games", name: "The 101 best PC games ever", url: "https://web.archive.org/web/20080711032338/http://www.computerandvideogames.com/article.php?id=164289" },
      { year: 2007, source: "Edge", name: "Edge's Top 100 Games of All Time", url: "https://web.archive.org/web/20120616065128/http://www.edge-online.com/features/edges-top-100-games-all-time" },
      { year: 2007, source: "IGN", name: "The Top 100 Games of All Time", url: "https://web.archive.org/web/20071203021612/http://top100.ign.com/2007/" },
      { year: 2006, source: "NA", name: "Game On! The 50 Greatest Video Games Of All Time", url: "https://archive.org/details/gameonfrompongto0000simo/page/246/mode/2up" },
      { year: 2005, source: "IGN", name: "IGN's Top 100 Games", url: "https://web.archive.org/web/20050724021903/http://top100.ign.com/2005/" },
      { year: 2005, source: "The Age", name: "The 50 best games", url: "https://www.theage.com.au/technology/the-50-best-games-20051006-gdm6uh.html" },
      { year: 2005, source: "Yahoo! UK", name: "The 100 Greatest Computer Games of All Time", url: "https://web.archive.org/web/20050731012158/http://uk.videogames.games.yahoo.com/specials/100games/1.html" },
      { year: 2003, source: "Entertainment Weekly", name: "We rank the 100 greatest early video games", url: "https://ew.com/article/2003/05/13/we-rank-100-greatest-videogames/" },
      { year: 2003, source: "GameSpot", name: "The Greatest Games of All Time", url: "https://web.archive.org/web/20080726155641/http://www.gamespot.com/gamespot/features/all/greatestgames/index.html" },
      { year: 2003, source: "IGN", name: "IGN's Top 100 Games of All Time", url: "https://web.archive.org/web/20141207120250/http://top100.ign.com/2003/" },
      { year: 2002, source: "Electronic Gaming Monthly", name: "100 Best Games Ever", url: "https://archive.org/details/electronic-gaming-monthly-issue-150-january-2002/page/n1/mode/2up" },
      { year: 2002, source: "The Sydney Morning Herald", name: "Top 50 video games of all time", url: "https://www.smh.com.au/lifestyle/top-50-video-games-of-all-time-20020606-gdfcdk.html" },
      { year: 2001, source: "GameSpy", name: "GameSpy's Top 50 Games of All Time", url: "https://web.archive.org/web/20040604135802/http://archive.gamespy.com/articles/july01/top50index/" },
      { year: 2000, source: "CNET", name: "The Top 40 Games of the Millennium", url: "https://web.archive.org/web/20000612222357/http://www.gamecenter.com/Features/Exclusives/Top40games/index.html" },
      { year: 2000, source: "Edge", name: "The 100 best games of all time", url: nil },
      { year: 2000, source: "GameSpot", name: "GameSpot's 100 Games of the Millennium", url: "https://web.archive.org/web/20000815090929/http://www.gamespot.co.uk/pc.gamespot/features/gotm_uk/" },
      { year: 1999, source: "Hyper", name: "The Top 50 Games of All Time", url: nil },
      { year: 1999, source: "Next Generation", name: "The Fifty Best Games of All Time", url: "https://archive.org/details/NextGeneration50Feb1999/page/n73/mode/2up" },
      { year: 1999, source: "The Independent", name: "The 50 Best Video games: A Legend In Your Own Living-Room", url: "https://www.independent.co.uk/arts-entertainment/the-50-best-video-games-a-legend-in-your-own-livingroom-1068932.html" },
      { year: 1997, source: "Electronic Gaming Monthly", name: "100 Best Games of All Time", url: "https://archive.org/details/electronic-gaming-monthly-issue-100-november-1997_202106/page/n105/mode/2up" },
      { year: 1997, source: "Hyper", name: "The 50 Best Games Ever!", url: nil },
      { year: 1996, source: "Computer Gaming World", name: "150 Best Games of All Time", url: nil },
      { year: 1996, source: "GamesMaster", name: "Top 100 Games of All Time", url: nil },
      { year: 1996, source: "Next Generation", name: "Top 100 Games of All Time", url: "https://archive.org/details/nextgen-issue-021/page/n39/mode/2up?view=theater" },
      { year: 1995, source: "Flux", name: "The Top 100 Video Games", url: "http://www.brettweisswords.com/2017/12/the-top-100-video-games-flux-magazine.html" },
      { year: 1995, source: "Hyper", name: "Top 100 Video Games of All Time", url: nil },
      { year: 1994, source: "GamesMaster", name: "The All Time Top 100 Ever", url: nil },
      { year: 1985, source: "NA", name: "The Greatest Games: The 93 Best Computer Games of All Time", url: nil },
      { year: 1984, source: "Electronic Fun with Computers & Games", name: "EF's 50 Best Games", url: nil }
    ]

    created = 0
    skipped = 0
    errors = []

    puts "Seeding #{lists_data.size} game lists..."
    puts

    lists_data.each do |data|
      existing = Games::List.find_by(
        name: data[:name],
        source: data[:source],
        year_published: data[:year]
      )

      if existing
        skipped += 1
        next
      end

      begin
        Games::List.create!(
          name: data[:name],
          source: data[:source],
          url: data[:url],
          year_published: data[:year],
          status: :unapproved
        )
        created += 1
      rescue => e
        errors << "#{data[:source]} (#{data[:year]}) - #{data[:name]}: #{e.message}"
      end
    end

    puts "Done!"
    puts "  Created: #{created}"
    puts "  Skipped (already exist): #{skipped}"
    puts "  Errors: #{errors.size}"
    if errors.any?
      puts
      puts "Errors:"
      errors.each { |e| puts "  - #{e}" }
    end
  end
end
