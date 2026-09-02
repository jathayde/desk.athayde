require "rails_helper"

RSpec.describe Memory::CheckRepoJob do
  let(:root) { Dir.mktmpdir("memory", Rails.root.join("tmp")) }
  after { FileUtils.rm_rf(root) }

  def with_repo_path(path) = allow(Rails.configuration.x.memory).to receive(:repo_path).and_return(path)

  it "records nothing when no path is configured" do
    with_repo_path(nil)
    described_class.perform_now
    expect(SyncRun.feed_memory_repo).to be_empty
  end

  it "records a failed run for a missing or empty mount, and a succeeded run with the file count when the files are there" do
    with_repo_path(File.join(root, "nope"))
    described_class.perform_now
    expect(SyncRun.feed_memory_repo.recent_first.first).to have_attributes(status: "failed", error: a_string_including("is not a directory"))

    with_repo_path(root)
    described_class.perform_now
    expect(SyncRun.feed_memory_repo.recent_first.first).to have_attributes(status: "failed", error: a_string_including("no memory files"))

    File.write(File.join(root, "strategy.md"), "v1")
    File.write(File.join(root, "notes.md"), "ignored")
    described_class.perform_now
    expect(SyncRun.feed_memory_repo.recent_first.first).to have_attributes(status: "succeeded", records_touched: 1, error: nil)
  end
end
