Rails.application.routes.draw do
  root "dashboard#show"

  resource :system, only: :show, controller: "system" do
    post :halt
    post :resume
  end
  resources :accounts, only: :update
  resources :trades, only: %i[ index show update ] do
    scope module: :trades do
      resource :review, only: %i[ show update ]
      resource :exclusion, only: :create
      resource :deferral, only: :create
    end
  end

  resource :session, only: %i[ new create destroy ]
  resource :magic_link, only: %i[ show create ]

  get "schwab/authorize", to: "schwab#authorize"
  get "schwab/callback", to: "schwab#callback"
  get "schwab/connected", to: "schwab#connected"
  get "schwab/fake_authorize", to: "schwab#fake_authorize"

  get "playwright/scenarios/:name", to: "playwright/scenarios#show", as: :playwright_scenario if Rails.env.test?

  get "up" => "rails/health#show", as: :rails_health_check
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
end
