namespace :agent do
  desc "Run a brief now: bin/rails agent:brief[morning_brief] or agent:brief[eod]"
  task :brief, [ :kind ] => :environment do |_, args|
    job = { "morning_brief" => Agent::MorningBriefJob, "eod" => Agent::EndOfDayJob }.fetch(args[:kind]) { abort "kind must be morning_brief or eod" }
    job.perform_now
    puts AgentRun.recent_first.first.then { |run| "#{run.title}: #{run.status}#{" (#{run.error})" if run.error}" }
  end

  desc "Resend a stored run's email without calling the API: bin/rails agent:resend[ID]"
  task :resend, [ :id ] => :environment do |_, args|
    run = AgentRun.find(args[:id])
    abort "#{run.title} is #{run.status}; nothing to send" unless run.deliverable?
    run.deliver!
    puts "sent #{run.title} to #{User.pluck(:email_address).join(', ')}"
  end
end
