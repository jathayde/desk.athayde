require "rails_helper"

RSpec.describe "config/initializers/credentials_check.rb" do
  let(:initializer) { Rails.root.join("config/initializers/credentials_check.rb").read }

  it "refuses a production boot with a missing secret, except during the image build" do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:anthropic, :api_key).and_return(nil)
    expect { eval(initializer) }.to raise_error(RuntimeError, /missing: .*anthropic\.api_key/) # rubocop:disable Security/Eval
    ENV["SECRET_KEY_BASE_DUMMY"] = "1"
    expect { eval(initializer) }.not_to raise_error # rubocop:disable Security/Eval
  ensure
    ENV.delete("SECRET_KEY_BASE_DUMMY")
  end
end
