require "rails_helper"

# Solid Queue evaluates the key lambda on the job instance at enqueue, a path perform_now never touches;
# a key that raises means a recurring task that silently never runs.
RSpec.describe "Job concurrency keys" do
  it "resolve for every job that limits concurrency" do
    Rails.application.eager_load!
    account = build_stubbed(:account)
    ApplicationJob.descendants.select { |job| job.concurrency_key.present? }.each do |job|
      arguments = job.instance_method(:perform).arity.zero? ? [] : [ account ]
      expect { job.new(*arguments).concurrency_key }.not_to raise_error, job.name
      expect(job.new(*arguments).concurrency_key).to be_present, job.name
    end
    expect(Memory::PullRepoJob.new.concurrency_key).to include("Memory::PullRepoJob")
    expect(Agent::SundayReviewJob.new.concurrency_key).to include("Agent::SundayReviewJob")
  end
end
