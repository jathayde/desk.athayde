Rails.application.routes.draw do
  root "dashboard#show"

  resource :session, only: %i[ new create destroy ]
  resource :magic_link, only: %i[ show create ]

  get "schwab/authorize", to: "schwab#authorize"
  get "schwab/callback", to: "schwab#callback"
  get "schwab/connected", to: "schwab#connected"
  get "schwab/fake_authorize", to: "schwab#fake_authorize"

  get "up" => "rails/health#show", as: :rails_health_check
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
end
