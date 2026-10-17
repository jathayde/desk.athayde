class ProposalsController < ApplicationController
  before_action :require_approver, only: %i[ new create ]

  def index
    @awaiting = OrderProposal.awaiting_hand_placement.includes(:instrument).order(:id)
    @queue = OrderProposal.queue.includes(:instrument, :setup)
    account = Account.trading.order(:id).first
    @reviews = account ? account.thesis_reviews.open.includes(:instrument).order(:created_at) : ThesisReview.none
    @decided_reviews = account ? account.thesis_reviews.where.not(decision: nil).includes(:instrument).order(decided_at: :desc).limit(5) : ThesisReview.none
    @decided = OrderProposal.decided.where.not(id: @awaiting).order(id: :desc).limit(10).includes(:instrument)
  end

  def show
    @proposal = OrderProposal.find(params[:id])
    @position = @proposal.account.positions.find_by(instrument: @proposal.instrument)
    collar = @proposal.collar.present? ? StopCollar::Collar.load(@proposal.collar) : nil
    @forecasts = @proposal.forecasts.to_a
    @own_forecast = @forecasts.find(&:author_human?)
    # Blind until the operator has added theirs or chosen to look (docs/phase-2.6-plan.md §0.2); the reader sees all.
    @forecast_revealed = @own_forecast || !@proposal.approvable? || !Current.user&.approver? || @proposal.agent_forecast_revealed_to?(Current.user)
    @chart = PriceChart.for(@proposal.instrument, stop: @proposal.stop_price || @position&.stop_price, entry: @proposal.limit_price, collar: collar)
  end

  def new
    @setups = Setup.active.order(:name)
    @hypotheses = Hypothesis.status_testing.includes(:setup).order(:id)
    @draft, @report = preview if params[:symbol].present?
  end

  def create
    arguments = proposal_arguments
    proposal = Proposals::Create.call(**arguments, origin: :human, user: Current.user, forecast: forecast_arguments(arguments[:kind]))
    redirect_to proposal_path(proposal), notice: "Proposed #{proposal.instrument.symbol}."
  rescue Proposals::Error, ArgumentError => e
    redirect_to new_proposal_path(params.permit(*Proposals::FORM_FIELDS)), alert: e.message
  end

  private
    # The form's preview: an unsaved draft judged by the same evaluator, nothing written.
    def preview
      draft = Proposals.draft(**proposal_arguments, origin: :human, user: Current.user)
      [ draft, Guardrails::Evaluator.new(draft).call ]
    rescue Proposals::Error, ArgumentError => e
      flash.now[:alert] = e.message
      nil
    end

    def proposal_arguments
      kind = params[:kind].presence_in(%w[ entry exit ]) || "entry" # a thesis review's deploy and exit arrive here too
      { account: Account.trading.order(:id).first, kind: kind, side: kind == "entry" ? :buy : :sell, symbol: params[:symbol].to_s,
        limit_price: decimal(params[:limit_price]), stop_price: decimal(params[:stop_price]),
        target_price: kind == "entry" ? decimal(params[:target_price]) : nil, hypothesis: Hypothesis.find_by(id: params[:hypothesis_id]), setup: Setup.find_by(id: params[:setup_id]),
        thesis: params[:thesis].presence, quantity: params[:quantity].presence&.to_i, tax_lot_method: params[:tax_lot_method].presence }
    end

    # The operator's forecast is optional (docs/phase-2.6-plan.md §0.2): none unless a probability is given.
    def forecast_arguments(kind)
      { probability: params[:probability], horizon_days: params[:horizon_days] } if kind == "entry" && params[:probability].present?
    end

    def decimal(value) = value.present? ? BigDecimal(value.to_s.strip) : nil
end
