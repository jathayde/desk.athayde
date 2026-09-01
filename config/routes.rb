Rails.application.routes.draw do
  root "dashboard#show"

  resource :session, only: %i[ new create destroy ]
  resource :magic_link, only: %i[ show create ]

  get "up" => "rails/health#show", as: :rails_health_check
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
end
