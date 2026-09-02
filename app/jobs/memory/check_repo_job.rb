module Memory
  # Every half hour, records what the host-pulled checkout holds as a memory_repo sync run: succeeded with the
  # file count when the known files are there, failed when the mount is missing or empty, nothing at all when no
  # path is configured. The pull itself is the host's cron (bin/dokku-setup); the app never writes the checkout.
  class CheckRepoJob < ApplicationJob
    limits_concurrency to: 1, key: ->(*) { self.class.name }, on_conflict: :discard

    def perform
      repo = Memory::Repo.configured
      return unless repo.path
      SyncRun.record(:memory_repo) do |run|
        if repo.empty? || !repo.present?
          run.error = repo.present? ? "no memory files at #{repo.path}" : "#{repo.path} is not a directory"
          next :failed
        end
        run.touched(repo.paths.size)
        run.error = "unreadable: #{repo.unreadable.join(', ')}" if repo.unreadable.any?
        repo.unreadable.any? ? :partial : :succeeded
      end
    end
  end
end
