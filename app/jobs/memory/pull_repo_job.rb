module Memory
  # Fast-forwards the memory checkout every half hour and records the outcome as a memory_repo sync run.
  # A pull that cannot fast-forward is a failed run for the digest, not an exception for the queue; the
  # briefs keep reading whatever is on disk. No path configured, no row: nothing to pull is not a failure.
  class PullRepoJob < ApplicationJob
    limits_concurrency to: 1, key: ->(*) { self.class.name }, on_conflict: :discard

    def perform
      repo = Memory::Repo.configured
      return unless repo.path
      SyncRun.record(:memory_repo) do |run|
        repo.pull!
        :succeeded
      rescue ArgumentError => e
        run.error = e.message
        :failed
      end
    end
  end
end
