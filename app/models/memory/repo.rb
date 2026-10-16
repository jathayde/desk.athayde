# The human-authored strategy files at MEMORY_REPO_PATH, read as text for the scheduled prompt. The checkout is
# owned and pulled on the host (bin/dokku-setup); Rails never writes here and never pulls in production. Files
# are snapshotted in one pass, capped, and scrubbed so a mid-pull read or a stray byte cannot break a run; a
# missing or empty checkout or an unreadable file is a degraded reason, not an exception.
class Memory::Repo
  FILES = %w[ investor-profile.md strategy.md watchlist.md prompts.md instructions.md edge.md deployment.md ].freeze
  PER_FILE_LIMIT = 32.kilobytes
  TOTAL_LIMIT = 128.kilobytes
  GIT_TIMEOUT = 60 # seconds; a fetch waiting on a remote must not hold the worker thread

  Entry = Data.define(:name, :text, :truncated)

  def self.configured = new(Rails.configuration.x.memory.repo_path)

  def initialize(path)
    @path = path.present? ? Pathname(path) : nil
  end

  attr_reader :path

  def present? = path&.directory? || false
  def empty? = present? && paths.empty?
  def git? = present? && path.join(".git").exist?
  def paths = present? ? FILES.map { |name| path.join(name) }.select(&:file?) : []

  def files
    read unless @files
    @files
  end

  def unreadable
    read unless @unreadable
    @unreadable
  end

  def truncated = files.select(&:truncated).map(&:name)
  def text(name) = files.find { |entry| entry.name == name }&.text
  def last_modified_at = paths.map(&:mtime).max
  def head_sha = git? ? git("rev-parse", "--short", "HEAD") : nil

  # A fast-forward pull for development and the memory:pull task; any other state (dirty, diverged, missing,
  # dubious ownership, a remote wanting credentials, a hung fetch) is the error text.
  def pull!
    raise ArgumentError, "MEMORY_REPO_PATH is not set" unless path
    raise ArgumentError, "#{path} is not a git checkout" unless git?
    git("pull", "--ff-only", "--quiet")
    head_sha
  end

  private
    def read
      @files, @unreadable = [], []
      budget = TOTAL_LIMIT
      paths.each do |file|
        text = file.binread.force_encoding(Encoding::UTF_8).scrub("\u{FFFD}").truncate_bytes([ PER_FILE_LIMIT, budget ].min, omission: "")
        budget -= text.bytesize
        @files << Entry.new(file.basename.to_s, text, text.bytesize < file.size)
      rescue SystemCallError => e
        @unreadable << "#{file.basename} (#{e.class.name.demodulize})"
      end
    end

    def git(*args)
      Open3.popen2e({ "GIT_TERMINAL_PROMPT" => "0" }, "git", "-C", path.to_s, "-c", "safe.directory=#{path}", *args) do |stdin, io, thread|
        stdin.close
        unless thread.join(GIT_TIMEOUT)
          Process.kill("KILL", thread.pid)
          raise ArgumentError, "git #{args.first} timed out after #{GIT_TIMEOUT}s"
        end
        output = io.read.strip
        raise ArgumentError, "git #{args.first}: #{output.lines.last.to_s.strip}" unless thread.value.success?
        output
      end
    end
end
