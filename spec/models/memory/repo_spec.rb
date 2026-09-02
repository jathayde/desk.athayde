require "rails_helper"

RSpec.describe Memory::Repo do
  let(:root) { Dir.mktmpdir("memory", Rails.root.join("tmp")) }
  after { FileUtils.rm_rf(root) }

  def git(dir, *args) = Open3.capture2e("git", "-C", dir, *args).then { |out, status| raise out unless status.success?; out.strip }

  def init_repo(dir)
    FileUtils.mkdir_p(dir)
    git(dir, "init", "-q", "-b", "main")
    git(dir, "config", "user.email", "spec@example.com")
    git(dir, "config", "user.name", "spec")
    File.write(File.join(dir, "strategy.md"), "v1")
    git(dir, "add", ".")
    git(dir, "commit", "-q", "-m", "one")
  end

  it "reads only the known files, capped and scrubbed, and reports what it truncated" do
    stub_const("Memory::Repo::PER_FILE_LIMIT", 8)
    File.write(File.join(root, "strategy.md"), "a" * 20)
    File.binwrite(File.join(root, "watchlist.md"), "ok\xFF")
    File.write(File.join(root, "secrets.md"), "never read")
    repo = described_class.new(root)
    expect(repo.files.map(&:name)).to eq(%w[ strategy.md watchlist.md ])
    expect(repo.files.first.text).to eq("a" * 8)
    expect(repo.files.last.text).to eq("ok\u{FFFD}")
    expect(repo.truncated).to eq([ "strategy.md" ])
    expect(repo.head_sha).to be_nil
    expect(repo.unreadable).to eq([])
  end

  it "stops reading at the total budget and names a file it cannot read as unreadable, not as an exception" do
    stub_const("Memory::Repo::TOTAL_LIMIT", 10)
    File.write(File.join(root, "strategy.md"), "a" * 6)
    File.write(File.join(root, "watchlist.md"), "b" * 6)
    File.write(File.join(root, "edge.md"), "c")
    File.chmod(0o000, File.join(root, "edge.md"))
    repo = described_class.new(root)
    expect(repo.files.map { |f| [ f.name, f.text, f.truncated ] }).to eq([ [ "strategy.md", "aaaaaa", false ], [ "watchlist.md", "bbbb", true ] ])
    expect(repo.unreadable).to eq([ "edge.md (EACCES)" ])
  ensure
    File.chmod(0o644, File.join(root, "edge.md"))
  end

  it "is absent without a path or a directory" do
    expect(described_class.new(nil)).to have_attributes(present?: false, files: [], paths: [], last_modified_at: nil)
    expect(described_class.new(File.join(root, "nope"))).to have_attributes(present?: false, git?: false)
    expect { described_class.new(nil).pull! }.to raise_error(ArgumentError, /MEMORY_REPO_PATH/)
    expect { described_class.new(root).pull! }.to raise_error(ArgumentError, /not a git checkout/)
  end

  it "fast-forwards a clean clone and refuses a diverged one with the git error" do
    origin = File.join(root, "origin")
    init_repo(origin)
    clone = File.join(root, "clone")
    git(root, "clone", "-q", origin, clone)
    File.write(File.join(origin, "strategy.md"), "v2")
    git(origin, "commit", "-qam", "two")
    repo = described_class.new(clone)
    expect(repo.pull!).to eq(git(origin, "rev-parse", "--short", "HEAD"))
    expect(repo.files.first.text).to eq("v2")

    File.write(File.join(clone, "strategy.md"), "local edit")
    git(clone, "commit", "-qam", "diverge")
    File.write(File.join(origin, "strategy.md"), "v3")
    git(origin, "commit", "-qam", "three")
    expect { repo.pull! }.to raise_error(ArgumentError, /git pull/)
  end

  it "kills a git that hangs and reports the timeout" do
    stub_const("Memory::Repo::GIT_TIMEOUT", 0.2)
    clone = File.join(root, "clone")
    init_repo(clone)
    repo = described_class.new(clone)
    allow(Open3).to receive(:popen2e).and_wrap_original do |original, *args, &block|
      original.call({ "GIT_TERMINAL_PROMPT" => "0" }, "sleep", "5", &block)
    end
    expect { repo.pull! }.to raise_error(ArgumentError, /timed out/)
  end
end
