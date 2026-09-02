require "rails_helper"

RSpec.describe "The native shell's Rails side" do
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:whitney) { create(:user, email_address: "whitney@athayde.com") }

  it "serves the path configuration without a session: a default that does not refresh, the forms as modals, the mobile-first screens refreshable" do
    get native_path_configuration_path
    expect(response).to have_http_status(:ok)
    rules = response.parsed_body.fetch("rules")
    expect(rules.first).to eq("patterns" => [ ".*" ], "properties" => { "context" => "default", "pull_to_refresh_enabled" => false })
    expect(rules.find { |r| r["properties"]["context"] == "modal" }["patterns"]).to include("^/session", "^/risk_rules")
    expect(rules.find { |r| r["properties"]["pull_to_refresh_enabled"] }["patterns"]).to include("^/proposals/\\d+$")
    expect(response.parsed_body.dig("settings", "screenshots_enabled")).to be(false)
  end

  it "registers a device once, refreshes it on re-registration, audits a move to the other user, and refuses an unknown platform" do
    sign_in john
    post native_devices_path, params: { platform: "ios", token: " abc ", app_version: "1.0" }
    expect(response).to have_http_status(:created)
    device = Device.sole
    expect(device).to have_attributes(user: john, platform: "ios", token: "abc", app_version: "1.0")
    expect(AuditEvent.where(kind: "device_registered", subject: device).sole.reason).to eq("registered")
    travel 1.day
    post native_devices_path, params: { platform: "ios", token: "abc", app_version: "1.1" }
    expect(Device.count).to eq(1)
    expect(device.reload.app_version).to eq("1.1")
    expect(device.last_seen_at).to be_within(1.minute).of(Time.current)
    expect(AuditEvent.where(kind: "device_registered").count).to eq(1)
    post native_devices_path, params: { platform: "android", token: "zzz" }
    expect(response).to have_http_status(:unprocessable_content)
    delete session_path
    sign_in whitney
    post native_devices_path, params: { platform: "ios", token: "abc" }
    expect(device.reload.user).to eq(whitney)
    expect(AuditEvent.where(kind: "device_registered").last.reason).to eq("reassigned")
  end

  it "answers a registration without a session with 401 and leaves the next web sign-in alone" do
    post native_devices_path, params: { platform: "ios", token: "abc" }
    expect(response).to have_http_status(:unauthorized)
    sign_in john
    expect(response).to redirect_to(root_path)
  end

  it "keeps forgery protection on: a registration carries the page's token, and one without it is refused" do
    sign_in john
    ActionController::Base.allow_forgery_protection = true
    post native_devices_path, params: { platform: "ios", token: "abc" }
    expect(response).to have_http_status(:unprocessable_content)
    get root_path, headers: { "User-Agent" => "Hotwire Native iOS" }
    token = response.body[/name="csrf-token" content="([^"]+)"/, 1]
    post native_devices_path, params: { platform: "ios", token: "abc" }, headers: { "X-CSRF-Token" => token, "User-Agent" => "Hotwire Native iOS" }
    expect(response).to have_http_status(:created)
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  it "gives the shell the brand and a sign-out, never the web navigation" do
    sign_in john
    get root_path, headers: { "User-Agent" => "Hotwire Native iOS" }
    expect(response.body).not_to include("shell-nav")
    expect(response.body).to include("Sign out")
    get root_path
    expect(response.body).to include("shell-nav")
  end
end
