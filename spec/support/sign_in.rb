module SignInHelper
  def sign_in(user)
    post magic_link_path, params: { token: user.magic_link_token }
  end
end

RSpec.configure { |c| c.include SignInHelper, type: :request }
