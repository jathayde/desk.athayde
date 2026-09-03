class ProposalsController < ApplicationController
  before_action :require_approver, only: %i[ new create ]

  def index
    @awaiting = OrderProposal.awaiting_hand_placement.includes(:instrument).order(:id)
    @queue = OrderProposal.queue.includes(:instrument, :setup)
    @decided = OrderProposal.decided.where.not(id: @awaiting).order(id: :desc).limit(10).includes(:instrument)
  end

  def show
    @proposal = OrderProposal.find(params[:id])
    @position = @proposal.account.positions.find_by(instrument: @proposal.instrument)
    collar = @proposal.collar.present? ? StopCollar::Collar.load(@proposal.collar) : nil
    @chart = PriceChart.for(@proposal.instrument, stop: @proposal.stop_price || @position&.stop_price, entry: @proposal.limit_price, collar: collar)
  end

  def new
    @setups = Setup.active.order(:name)
    @draft, @report = preview if params[:symbol].present?
  end

  def create
    proposal = Proposals::Create.call(**proposal_arguments, origin: :human, user: Current.user)
    redirect_to proposal_path(proposal), notice: "Proposed #{proposal.instrument.symbol}."
  rescue Proposals::Error, ArgumentError => e
    redirect_to new_proposal_path(params.permit(:kind, :symbol, :limit_price, :stop_price, :setup_id, :thesis, :quantity, :tax_lot_method)), alert: e.message
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
      kind = params[:kind].presence_in(%w[ entry exit ]) || "entry"
      { account: Account.trading.order(:id).first, kind: kind, side: kind == "entry" ? :buy : :sell, symbol: params[:symbol].to_s,
        limit_price: decimal(params[:limit_price]), stop_price: decimal(params[:stop_price]), setup: Setup.find_by(id: params[:setup_id]),
        thesis: params[:thesis].presence, quantity: params[:quantity].presence&.to_i, tax_lot_method: params[:tax_lot_method].presence }
    end

    def decimal(value) = value.present? ? BigDecimal(value.to_s.strip) : nil
end
