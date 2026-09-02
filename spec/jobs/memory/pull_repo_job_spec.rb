require "rails_helper"

RSpec.describe Memory::PullRepoJob do
  let(:root) { Dir.mktmpdir("memory", Rails.root.join("tmp")) }
  after { FileUtils.rm_rf(root) }

  def with_repo_path(path)
    allow(Rails.configuration.x.memory).to receive(:repo_path).and_return(path)
  end

  it "records nothing when no path is configured" do
    with_repo_path(nil)
    described_class.perform_now
    expect(SyncRun.feed_memory_repo).to be_empty
  end

  it "records a failed memory_repo run with git's reason for a checkout it cannot pull, and never raises" do
    with_repo_path(root)
    described_class.perform_now
    expect(SyncRun.feed_memory_repo.last).to have_attributes(status: "failed", error: a_string_including("not a git checkout"))
  end

  it "records a succeeded run for a fast-forward, and leaves nothing running when git itself is missing" do
    with_repo_path(root)
    allow_any_instance_of(Memory::Repo).to receive(:pull!).and_return("abc123")
    described_class.perform_now
    expect(SyncRun.feed_memory_repo.recent_first.first).to have_attributes(status: "succeeded", error: nil)

    allow_any_instance_of(Memory::Repo).to receive(:pull!).and_raise(Errno::ENOENT, "git")
    expect { described_class.perform_now }.to raise_error(Errno::ENOENT)
    expect(SyncRun.feed_memory_repo.recent_first.first).to have_attributes(status: "failed", error: a_string_including("Errno::ENOENT"))
    expect(SyncRun.running).to be_empty
  end
end
