require "test_helper"

class TurboFrameLinksTest < ActiveSupport::TestCase
  def candidates(html, **options)
    TurboFrameLinks.trapped_candidates(html, **options)
  end

  def pairs(result)
    result.map { |candidate| [candidate.href, candidate.frame_id] }
  end

  test "a link inside a frame is scoped to that frame" do
    result = candidates(<<~HTML)
      <turbo-frame id="list_items"><a href="/book/war-and-peace">W&amp;P</a></turbo-frame>
    HTML

    assert_equal [["/book/war-and-peace", "list_items"]], pairs(result)
  end

  test "a link outside every frame is unscoped" do
    assert_empty candidates(%(<a href="/book/war-and-peace">W&amp;P</a>))
  end

  test "a link that targets _top escapes its frame" do
    assert_empty candidates(<<~HTML)
      <turbo-frame id="list_items">
        <a href="/book/war-and-peace" data-turbo-frame="_top">W&amp;P</a>
      </turbo-frame>
    HTML
  end

  test "a frame that targets _top releases every link inside it" do
    assert_empty candidates(<<~HTML)
      <turbo-frame id="list_items" target="_top">
        <a href="/book/war-and-peace">W&amp;P</a>
      </turbo-frame>
    HTML
  end

  test "a frame's target names the frame an inner link actually navigates" do
    result = candidates(<<~HTML)
      <turbo-frame id="sidebar" target="content">
        <a href="/album/animals">Animals</a>
      </turbo-frame>
    HTML

    assert_equal [["/album/animals", "content"]], pairs(result)
  end

  test "an explicit data-turbo-frame overrides the frame's own target" do
    result = candidates(<<~HTML)
      <turbo-frame id="list_items" target="_top">
        <a href="/my/lists/1/page/2" data-turbo-frame="list_items">2</a>
      </turbo-frame>
    HTML

    assert_equal [["/my/lists/1/page/2", "list_items"]], pairs(result)
  end

  test "the nearest enclosing frame wins when frames are nested" do
    result = candidates(<<~HTML)
      <turbo-frame id="outer">
        <turbo-frame id="inner"><a href="/nested">n</a></turbo-frame>
      </turbo-frame>
    HTML

    assert_equal ["inner"], result.map(&:frame_id)
  end

  test "a link inside a table inside a frame is still attributed to the frame" do
    result = candidates(<<~HTML)
      <turbo-frame id="list_items">
        <table><tbody><tr><td><a href="/song/time">Time</a></td></tr></tbody></table>
      </turbo-frame>
    HTML

    assert_equal ["list_items"], result.map(&:frame_id)
  end

  test "data-turbo=false opts a link out of Turbo entirely" do
    assert_empty candidates(<<~HTML)
      <turbo-frame id="list_items">
        <a href="/my/lists/1.csv" data-turbo="false">Download</a>
      </turbo-frame>
    HTML
  end

  test "fragment, mailto and tel links are not followable" do
    assert_empty candidates(<<~HTML)
      <turbo-frame id="list_items">
        <a href="#top">top</a>
        <a href="mailto:someone@example.com">mail</a>
        <a href="tel:+15551234567">call</a>
      </turbo-frame>
    HTML
  end

  test "an absolute link to another host is not followable" do
    assert_empty candidates(<<~HTML, host: "books.example.com")
      <turbo-frame id="list_items"><a href="https://example.com/x">x</a></turbo-frame>
    HTML
  end

  test "an absolute link to the current host is followable" do
    result = candidates(<<~HTML, host: "books.example.com")
      <turbo-frame id="list_items">
        <a href="https://books.example.com/album/animals">Animals</a>
      </turbo-frame>
    HTML

    assert_equal ["list_items"], result.map(&:frame_id)
  end

  test "repeated href and frame pairs collapse to a single candidate" do
    result = candidates(<<~HTML)
      <turbo-frame id="list_items">
        <a href="/album/animals"><span>cover</span></a>
        <a href="/album/animals">Animals</a>
      </turbo-frame>
    HTML

    assert_equal 1, result.size
  end
end
