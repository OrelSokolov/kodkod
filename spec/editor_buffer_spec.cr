require "spec"
require "../src/editor_buffer"

describe Kodkod::EditorBuffer do
  it "applies edits to the rope and marks dirty" do
    b = Kodkod::EditorBuffer.new("hello world")
    b.apply(5, ",", 0)
    b.text.should eq("hello, world")
    b.dirty?.should be_true
    b.undoable?.should be_true
  end

  it "undo and redo restore text and give cursor hints" do
    b = Kodkod::EditorBuffer.new("abc")
    b.apply(0, "X", 0)
    b.apply(2, "Y", 0)
    b.text.should eq("XaYbc")

    _edit, hint = b.undo.not_nil!
    hint.should eq(2) # caret at end of restored text (nothing deleted)
    b.text.should eq("Xabc")

    _edit, hint = b.undo.not_nil!
    b.text.should eq("abc")

    b.undoable?.should be_false
    b.undo.should be_nil

    _edit, hint = b.redo.not_nil!
    hint.should eq(1)
    b.text.should eq("Xabc")
    b.redo.not_nil![0].inserted.should eq("Y")
    b.text.should eq("XaYbc")
  end

  it "deletes through apply and undo restores the deleted text" do
    b = Kodkod::EditorBuffer.new("hello world")
    b.apply(5, "", 6) # delete " world"
    b.text.should eq("hello")
    _e, hint = b.undo.not_nil!
    hint.should eq(11)
    b.text.should eq("hello world")
  end

  it "bumps the rope version on every edit" do
    b = Kodkod::EditorBuffer.new("x")
    v0 = b.version
    b.apply(0, "y", 0)
    b.version.should eq(v0 + 1)
  end

  it "computes token spans lazily per version" do
    b = Kodkod::EditorBuffer.new("def foo\nend\n", lang: "crystal")
    spans = b.token_spans
    spans.should_not be_nil
    starts, toks = spans.not_nil!
    toks.map(&.text).join.should eq("def foo\nend\n")
    starts[0].should eq(0)

    b.apply(0, "# ", 0)
    spans2 = b.token_spans.not_nil!
    # recomputed for the new version (coverage invariant)
    spans2[1].map(&.text).join.should eq("# def foo\nend\n")
  end

  it "returns no spans for unknown languages" do
    b = Kodkod::EditorBuffer.new("hello", lang: "no-such-lang")
    # The registry has no entry — token_spans must degrade to nil
    # (plain rendering), never raise.
    b.token_spans.should be_nil
  end

  it "detects external changes through disk_mtime" do
    path = File.tempname("kodkod", ".cr")
    File.write(path, "x = 1\n")
    begin
      b = Kodkod::EditorBuffer.new(File.read(path), path: path)
      b.disk_mtime = File.info(path).modification_time
      b.changed_on_disk?.should be_false
      # An external write (or a plain touch) moves the mtime.
      File.touch(path, Time.utc + 1.minute)
      b.changed_on_disk?.should be_true
      # Re-syncing on our own save swallows the event.
      b.disk_mtime = File.info(path).modification_time
      b.changed_on_disk?.should be_false
    ensure
      File.delete(path)
    end
  end

  it "treats a missing file as unchanged (nothing to reload)" do
    b = Kodkod::EditorBuffer.new("x", path: "/no/such/file/kodkod.spec")
    b.changed_on_disk?.should be_false
  end
end
