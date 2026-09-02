# Push::Deliver never raises, so this job never retries: a push that did not land is reported, and the email went.
class Push::DeliverJob < ApplicationJob
  def perform(title:, body:, path:) = Push::Deliver.call(title: title, body: body, path: path)
end
