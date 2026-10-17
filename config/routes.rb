Rails.application.routes.draw do
  root "dashboard#show"

  match "/mcp", to: "mcp#handle", via: %i[ post get delete ]

  resource :research, only: :show, controller: "research"
  resource :system, only: :show, controller: "system" do
    post :halt
    post :resume
    post :shadow_mode
  end
  resources :risk_rules, only: %i[ index update ] do
    get :preview, on: :member
  end
  resource :deployment_policy, only: :update
  resources :fund_flows, only: :create
  resources :allocation_targets, path: "allocation", only: %i[ index create update ] do
    resource :retirement, only: :create, module: :allocation_targets
    resource :rejection_clearance, only: :create, module: :allocation_targets
  end
  resources :proposals, only: %i[ index show new create ] do
    scope module: :proposals do
      resource :approval, only: :create
      resource :rejection, only: :create
      resource :forecast, only: :create
      resource :forecast_reveal, only: :create
    end
  end
  resources :thesis_reviews, only: :show do
    resource :decision, only: :create, module: :thesis_reviews
  end
  resources :watchlist_items, path: "watchlist", only: %i[ index create ] do
    resource :drop, only: :create, module: :watchlist_items
  end
  resources :accounts, only: :update
  resources :instruments, only: :update do
    resource :classification, only: :update, module: :instruments
  end
  resources :trades, only: %i[ index show update ] do
    scope module: :trades do
      resource :review, only: %i[ show update ]
      resource :exclusion, only: :create
      resource :deferral, only: :create
    end
  end

  namespace :native do
    resource :path_configuration, only: :show, defaults: { format: :json }
    resources :devices, only: :create, defaults: { format: :json }
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
