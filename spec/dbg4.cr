require "../src/syntax"

text = File.read("spec/syntax_spec.cr")
toks = Kodkod::Syntax.highlight(text, "crystal").not_nil!
acc = 0
line = 1
interesting = false
toks.each do |t|
  lines = t.text.count('\n')
  if line >= 183 && line <= 192
    first = t.text.split("\n").first
    puts "L#{line} #{t.scope.inspect} #{first.inspect} (+#{lines} nl)"
  end
  line += lines
  acc += t.text.size
end
