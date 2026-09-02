namespace :memory do
  desc "Fast-forward the memory checkout at MEMORY_REPO_PATH (development; production pulls on the host)"
  task pull: :environment do
    puts "pulled #{Memory::Repo.configured.pull!}"
  end
end
