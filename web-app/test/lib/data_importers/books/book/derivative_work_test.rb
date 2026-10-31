# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      class DerivativeWorkTest < ActiveSupport::TestCase
        # Goodreads export title => the book the finder wrongly picked (2026-10-31 rebuild).
        DIFFERENT = [
          ["Watership Down: The Graphic Novel", "Watership Down"],
          ["The Lion, the Witch and the Wardrobe: A Graphic Novel", "The Lion, the Witch and the Wardrobe"],
          ["The Alchemist: A Graphic Novel", "The Alchemist"],
          ["Stolz und Vorurteil: die Graphic Novel nach Jane Austen", "Pride and Prejudice"],
          ["Así habló Zaratustra: el Manga", "Thus Spake Zarathustra"],
          ["Alice's Adventures in Wonderland: A Pop-Up Adaptation", "Alice's Adventures in Wonderland"],
          ["The Wonderful Wizard of Oz: A Commemorative Pop-Up", "The Wonderful Wizard of Oz"],
          ["Moby-Dick: A Pop-Up Book from the Novel by Herman Melville", "Moby-Dick"],
          ["The Truth: Stage Adaptation", "The Truth"],
          ["Night Watch: Stage Adaptation", "Night Watch"],
          ["Going Postal: Stage Adaptation", "Going Postal"],
          ["Guards! Guards!: The Play", "Guards! Guards!"],
          ["Hamlet: Screenplay, Introduction And Film Diary", "Hamlet"],
          ["The Odyssey: A Dramatic Retelling of Homer's Epic", "The Odyssey"],
          ["Trojan Women: The most celebrated Classical Greek Tragedy revisited", "Trojan Women"],
          ["The Apology of Socrates: Adapted for the Contemporary Reader", "Apology"],
          ["The Great Gatsby By F. Scott Fitzgerald: Literature Guide", "The Great Gatsby"],
          ["Seveneves: A Novel by Neal Stephenson | Summary & Analysis", "Seveneves"],
          ["Sense and Sensibility: A Guide to Reading and Reflecting", "Sense and Sensibility"],
          ["Elucidating Alice: A Textual Commentary on Alice's Adventures in Wonderland", "Alice's Adventures in Wonderland"],
          ["Sapiens: Une bande dessinée", "Sapiens"],
          ["Don Quijote: Novela gráfica", "Don Quijote"],
          ["Pride and Prejudice (Manga Classics)", "Pride and Prejudice"],
          ["Animal Farm (Graphic Novel)", "Animal Farm"],
          ["Watership Down - A Graphic Novel", "Watership Down"],
          ["Hamlet – The Manga", "Hamlet"],
          ["Hamlet — The Manga", "Hamlet"],
          ["SparkNotes Hamlet", "Hamlet"],
          ["CliffsNotes on Hamlet", "Hamlet"],
          ["Hamlet: The Graphic Novel", "Hamlet: Study Guide"]
        ].freeze

        # Translations and editions of the same work.
        SAME = [
          ["La tabla rasa", "The Blank Slate"],
          ["Lo hobbit", "The Hobbit"],
          ["Nel nome del figlio: Hamnet", "Hamnet"],
          ["Le Morte D'Arthur (Norton Critical Edition)", "Le Morte d'Arthur"],
          ["From the Earth to the Moon: Annotated Jules Verne", "From the Earth to the Moon"],
          ["The Táin: From the Irish Epic", "The Táin"],
          ["Tao Te Ching: A New Translation", "Tao Te Ching"],
          ["The Dhammapada: A Translation of the Buddhist Classic with Annotations", "The Dhammapada"],
          ["I Ching: The Book of Change (Shambhala Pocket Classics)", "I Ching"],
          ["Poor Charlie's Almanack: The Wit and Wisdom of Charles T. Munger, Expanded Third Edition", "Poor Charlie's Almanack"],
          ["1Q84 3 Volume Box", "1Q84"],
          ["The Illustrated Hobbit", "The Hobbit"],
          ["Watership Down: A Graphic Novel", "Watership Down: The Graphic Novel"],
          # A marker inside the work's own name is not a derivative marker.
          ["Introductory Lectures on Psychoanalysis", "Introductory Lectures on Psycho-Analysis"],
          ["Retour à Brideshead", "Brideshead Revisited"],
          ["Manifeste des espèces compagnes", "The Companion Species Manifesto"],
          ["Brideshead Revisited", "Brideshead Revisited"],
          ["Psycho-Analysis", "Psychoanalysis"],
          ["Alice: A Pop-Up Adaptation", "Alice: A Pop-Up Book"],
          ["Don Quijote: Graphic Novel", "Don Quijote: Novela gráfica"]
        ].freeze

        DIFFERENT.each do |query, candidate|
          test "#{query.inspect} is a different book from #{candidate.inspect}, in both directions" do
            assert DerivativeWork.differ?(query, candidate)
            assert DerivativeWork.differ?(candidate, query)
          end
        end

        SAME.each do |query, candidate|
          test "#{query.inspect} is not told apart from #{candidate.inspect}" do
            refute DerivativeWork.differ?(query, candidate)
          end
        end

        test "markers match whole words only" do
          assert_equal [], DerivativeWork.markers("The Playboy of the Western World")
          assert_equal [], DerivativeWork.markers("Mangrove Summers")
        end

        test "a blank title carries no markers" do
          assert_equal [], DerivativeWork.markers(nil)
          refute DerivativeWork.differ?("", nil)
        end
      end
    end
  end
end
