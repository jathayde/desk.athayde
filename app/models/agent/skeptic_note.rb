# The skeptic prompt's contract (app/models/agent/prompts/skeptic_system.md.erb): prose, then a last line naming the
# strongest objection from a fixed list. Read loosely, since models bold and punctuate: the last non-blank line is
# the risk line when it starts with "risk", whatever word follows, and it never stays in the note; a word off the
# list is "other". A note longer than the prompt allows is cut, and says so.
module Agent::SkepticNote
  RISKS = %w[ thesis timing sample cost trend other ].freeze
  LIMIT = 2_000

  Parsed = Data.define(:note, :risk)

  def self.parse(text)
    lines = text.to_s.strip.lines.map(&:rstrip).reject(&:blank?)
    named = lines.last.to_s.match(/\A\W*risk\W*\s*(\w*)/i)
    risk = named && RISKS.include?(named[1].downcase) ? named[1].downcase : "other"
    note = (named ? lines[0...-1] : lines).join("\n").strip
    note = "#{note.truncate(LIMIT, separator: " ", omission: "")} [cut at #{LIMIT} characters]" if note.length > LIMIT
    Parsed.new(note: note, risk: risk)
  end
end
