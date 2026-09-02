# After every whole orders sync, once stops are assigned: a position that should be protected and is not gets
# the hard alert (PRD §5.4.2), once per position per day, audited.
class Orders::ProtectionWatch
  ALERT_GAP = 1.day

  def self.call(account) = new(account).call

  def initialize(account) = @account = account

  def call
    @account.positions.includes(:instrument, :working_stop_order).each do |position|
      next unless position.unprotected? && expected_protection?(position) && !alerted_recently?(position)
      Alert.unprotected_position(position)
      AuditEvent.log("unprotected_alert_sent", actor: :system, subject: position, data: { symbol: position.instrument.symbol, protection: position.protection })
    end
  end

  private
    # "Should be protected": we bought it with a bracket, we just touched its stop, or its stop died at the broker today.
    def expected_protection?(position) = we_bought_it?(position) || we_touched_its_stop?(position) || its_stop_died?(position)

    def we_bought_it?(position) = @account.order_proposals.filled.where(instrument: position.instrument, kind: :entry).exists?
    def we_touched_its_stop?(position) = @account.order_proposals.where(instrument: position.instrument, decided_at: ALERT_GAP.ago..).where.not(child_action: nil).exists?
    def its_stop_died?(position) = @account.orders.where(instrument: position.instrument).stops.sells.where(status: Schwab::Order::DEAD_STATUSES + [ Schwab::Order::GONE ], closed_at: ALERT_GAP.ago..).exists?
    def alerted_recently?(position) = AuditEvent.where(kind: "unprotected_alert_sent", subject: position, created_at: ALERT_GAP.ago..).exists?
end
