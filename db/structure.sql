SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: audit_events_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_events_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'audit_events is append-only';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounts (
    id bigint NOT NULL,
    schwab_hash character varying NOT NULL,
    account_type character varying,
    trading_enabled boolean DEFAULT false NOT NULL,
    nickname character varying,
    last_synced_at timestamp(6) with time zone,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: accounts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: accounts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.accounts_id_seq OWNED BY public.accounts.id;


--
-- Name: activities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activities (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    instrument_id bigint,
    order_id bigint,
    broker_order_id character varying,
    broker_activity_id character varying NOT NULL,
    kind character varying NOT NULL,
    sub_type character varying,
    side character varying,
    quantity numeric(18,6),
    price numeric(18,4),
    commission numeric(18,4) DEFAULT 0.0 NOT NULL,
    fees numeric(18,4) DEFAULT 0.0 NOT NULL,
    net_amount numeric(18,4),
    trade_date date,
    settlement_date date,
    executed_at timestamp(6) with time zone NOT NULL,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    journaled_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    status character varying
);


--
-- Name: activities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.activities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.activities_id_seq OWNED BY public.activities.id;


--
-- Name: agent_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_runs (
    id bigint NOT NULL,
    kind character varying NOT NULL,
    status character varying NOT NULL,
    degraded boolean DEFAULT false NOT NULL,
    started_at timestamp(6) with time zone,
    finished_at timestamp(6) with time zone,
    tool_turns integer DEFAULT 0 NOT NULL,
    input_tokens integer,
    output_tokens integer,
    estimated_cost numeric(18,4),
    output_markdown text,
    error text,
    model character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    market_date date,
    stop_reason character varying,
    emailed_at timestamp with time zone,
    cache_creation_input_tokens integer,
    cache_read_input_tokens integer,
    tool_calls_count integer DEFAULT 0 NOT NULL,
    degraded_reasons jsonb DEFAULT '[]'::jsonb NOT NULL,
    transcript jsonb DEFAULT '[]'::jsonb NOT NULL
);


--
-- Name: agent_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_runs_id_seq OWNED BY public.agent_runs.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    id bigint NOT NULL,
    kind character varying NOT NULL,
    actor character varying NOT NULL,
    user_id bigint,
    subject_type character varying,
    subject_id bigint,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    reason text,
    created_at timestamp(6) with time zone NOT NULL
);


--
-- Name: audit_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_events_id_seq OWNED BY public.audit_events.id;


--
-- Name: balances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.balances (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    as_of timestamp(6) with time zone NOT NULL,
    equity numeric(18,4),
    cash_available_for_trading numeric(18,4),
    unsettled_cash numeric(18,4),
    settled_cash numeric(18,4),
    buying_power numeric(18,4),
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: balances_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.balances_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: balances_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.balances_id_seq OWNED BY public.balances.id;


--
-- Name: devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.devices (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    platform character varying NOT NULL,
    token character varying NOT NULL,
    app_version character varying,
    last_seen_at timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: devices_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.devices_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: devices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.devices_id_seq OWNED BY public.devices.id;


--
-- Name: instruments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.instruments (
    id bigint NOT NULL,
    cusip character varying,
    schwab_instrument_id bigint,
    symbol character varying NOT NULL,
    symbol_history jsonb DEFAULT '[]'::jsonb NOT NULL,
    asset_type character varying,
    leveraged boolean DEFAULT false NOT NULL,
    description character varying,
    predecessor_instrument_id bigint,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    delisted_at timestamp with time zone,
    delisted_price numeric(18,4)
);


--
-- Name: instruments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.instruments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: instruments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.instruments_id_seq OWNED BY public.instruments.id;


--
-- Name: market_days; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.market_days (
    id bigint NOT NULL,
    date date NOT NULL,
    trading boolean NOT NULL,
    session_opens_at timestamp(6) with time zone,
    regular_opens_at timestamp(6) with time zone,
    regular_closes_at timestamp(6) with time zone,
    session_closes_at timestamp(6) with time zone,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    fetched_at timestamp(6) with time zone NOT NULL,
    source character varying DEFAULT 'schwab'::character varying NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: market_days_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.market_days_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: market_days_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.market_days_id_seq OWNED BY public.market_days.id;


--
-- Name: order_proposals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_proposals (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    instrument_id bigint NOT NULL,
    kind character varying DEFAULT 'entry'::character varying NOT NULL,
    target_order_id bigint,
    origin character varying NOT NULL,
    user_id bigint,
    status character varying DEFAULT 'proposed'::character varying NOT NULL,
    side character varying,
    quantity numeric(18,6),
    order_type character varying,
    limit_price numeric(18,4),
    stop_price numeric(18,4),
    planned_stop numeric(18,4),
    target_price numeric(18,4),
    duration character varying,
    session character varying,
    tax_lot_method character varying,
    thesis text,
    setup_id bigint,
    guardrail_results jsonb DEFAULT '{}'::jsonb NOT NULL,
    acknowledged_warnings jsonb DEFAULT '[]'::jsonb NOT NULL,
    override_reason text,
    rejection_reason text,
    submitted_at timestamp(6) with time zone,
    expires_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    collar jsonb DEFAULT '{}'::jsonb NOT NULL,
    sizing jsonb DEFAULT '{}'::jsonb NOT NULL,
    evaluated_at timestamp with time zone,
    decided_at timestamp with time zone,
    decided_by_id bigint,
    shadow boolean DEFAULT false NOT NULL,
    broker_order_id character varying,
    parent_proposal_id bigint,
    child_action character varying,
    lots jsonb DEFAULT '[]'::jsonb NOT NULL
);


--
-- Name: order_proposals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.order_proposals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: order_proposals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.order_proposals_id_seq OWNED BY public.order_proposals.id;


--
-- Name: orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    instrument_id bigint,
    broker_order_id character varying NOT NULL,
    status character varying NOT NULL,
    side character varying,
    quantity numeric(18,6),
    filled_quantity numeric(18,6),
    order_type character varying,
    limit_price numeric(18,4),
    stop_price numeric(18,4),
    duration character varying,
    session character varying,
    tax_lot_method character varying,
    placed_via character varying DEFAULT 'schwab_direct'::character varying NOT NULL,
    parent_order_id bigint,
    replaces_order_id bigint,
    order_proposal_id bigint,
    entered_at timestamp(6) with time zone,
    closed_at timestamp(6) with time zone,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    remaining_quantity numeric(18,6),
    strategy_type character varying
);


--
-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.orders_id_seq OWNED BY public.orders.id;


--
-- Name: positions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.positions (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    instrument_id bigint NOT NULL,
    quantity numeric(18,6) NOT NULL,
    average_price numeric(18,4),
    cost_basis numeric(18,4),
    market_value numeric(18,4),
    last_price numeric(18,4),
    working_stop_order_id bigint,
    synced_at timestamp(6) with time zone NOT NULL,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    suggested_stop numeric(18,4),
    suggested_stop_method character varying,
    suggested_at timestamp with time zone
);


--
-- Name: positions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.positions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: positions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.positions_id_seq OWNED BY public.positions.id;


--
-- Name: risk_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.risk_rules (
    id bigint NOT NULL,
    rule_type character varying NOT NULL,
    params jsonb DEFAULT '{}'::jsonb NOT NULL,
    active boolean DEFAULT true NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    setup_id bigint,
    superseded_by_id bigint,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    mode character varying DEFAULT 'block'::character varying NOT NULL,
    note text,
    changed_by_id bigint
);


--
-- Name: risk_rules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.risk_rules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: risk_rules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.risk_rules_id_seq OWNED BY public.risk_rules.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: schwab_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schwab_tokens (
    id bigint NOT NULL,
    access_token text NOT NULL,
    refresh_token text NOT NULL,
    access_expires_at timestamp(6) with time zone NOT NULL,
    refresh_expires_at timestamp(6) with time zone NOT NULL,
    issued_at timestamp(6) with time zone NOT NULL,
    last_refreshed_at timestamp(6) with time zone,
    last_refresh_error text,
    scope character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    revoked_at timestamp(6) with time zone
);


--
-- Name: schwab_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.schwab_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: schwab_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.schwab_tokens_id_seq OWNED BY public.schwab_tokens.id;


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    ip_address character varying,
    user_agent character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sessions_id_seq OWNED BY public.sessions.id;


--
-- Name: setups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.setups (
    id bigint NOT NULL,
    name character varying NOT NULL,
    definition text,
    active boolean DEFAULT true NOT NULL,
    win_rate numeric(6,4),
    avg_r numeric(10,4),
    sample_size integer DEFAULT 0 NOT NULL,
    stats_computed_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: setups_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.setups_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: setups_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.setups_id_seq OWNED BY public.setups.id;


--
-- Name: snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.snapshots (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    as_of date NOT NULL,
    equity numeric(18,4) NOT NULL,
    net_flows numeric(18,4) DEFAULT 0.0 NOT NULL,
    daily_return numeric(12,8),
    index_value numeric(18,10) DEFAULT 1.0 NOT NULL,
    high_water_index numeric(18,10) DEFAULT 1.0 NOT NULL,
    drawdown numeric(10,6) DEFAULT 0.0 NOT NULL,
    open_risk_amount numeric(18,4),
    open_risk_ratio numeric(10,6),
    unprotected_count integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: snapshots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.snapshots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: snapshots_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.snapshots_id_seq OWNED BY public.snapshots.id;


--
-- Name: solid_cable_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_cable_messages (
    id bigint NOT NULL,
    channel bytea NOT NULL,
    payload bytea NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    channel_hash bigint NOT NULL
);


--
-- Name: solid_cable_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_cable_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_cable_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_cable_messages_id_seq OWNED BY public.solid_cable_messages.id;


--
-- Name: solid_cache_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_cache_entries (
    id bigint NOT NULL,
    key bytea NOT NULL,
    value bytea NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    key_hash bigint NOT NULL,
    byte_size integer NOT NULL
);


--
-- Name: solid_cache_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_cache_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_cache_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_cache_entries_id_seq OWNED BY public.solid_cache_entries.id;


--
-- Name: solid_queue_batch_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_batch_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    batch_id bigint NOT NULL,
    created_at timestamp(6) with time zone NOT NULL
);


--
-- Name: solid_queue_batch_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_batch_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_batch_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_batch_executions_id_seq OWNED BY public.solid_queue_batch_executions.id;


--
-- Name: solid_queue_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_batches (
    id bigint NOT NULL,
    active_job_batch_id character varying,
    description character varying,
    on_finish text,
    on_success text,
    on_failure text,
    metadata text,
    total_jobs integer DEFAULT 0 NOT NULL,
    completed_jobs integer DEFAULT 0 NOT NULL,
    failed_jobs integer DEFAULT 0 NOT NULL,
    enqueued_at timestamp(6) with time zone,
    finished_at timestamp(6) with time zone,
    failed_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: solid_queue_batches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_batches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_batches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_batches_id_seq OWNED BY public.solid_queue_batches.id;


--
-- Name: solid_queue_blocked_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_blocked_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    queue_name character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    concurrency_key character varying NOT NULL,
    expires_at timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL
);


--
-- Name: solid_queue_blocked_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_blocked_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_blocked_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_blocked_executions_id_seq OWNED BY public.solid_queue_blocked_executions.id;


--
-- Name: solid_queue_claimed_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_claimed_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    process_id bigint,
    created_at timestamp(6) with time zone NOT NULL
);


--
-- Name: solid_queue_claimed_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_claimed_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_claimed_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_claimed_executions_id_seq OWNED BY public.solid_queue_claimed_executions.id;


--
-- Name: solid_queue_failed_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_failed_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    error text,
    created_at timestamp(6) with time zone NOT NULL
);


--
-- Name: solid_queue_failed_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_failed_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_failed_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_failed_executions_id_seq OWNED BY public.solid_queue_failed_executions.id;


--
-- Name: solid_queue_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_jobs (
    id bigint NOT NULL,
    queue_name character varying NOT NULL,
    class_name character varying NOT NULL,
    arguments text,
    priority integer DEFAULT 0 NOT NULL,
    active_job_id character varying,
    scheduled_at timestamp(6) with time zone,
    finished_at timestamp(6) with time zone,
    concurrency_key character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    batch_id bigint
);


--
-- Name: solid_queue_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_jobs_id_seq OWNED BY public.solid_queue_jobs.id;


--
-- Name: solid_queue_pauses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_pauses (
    id bigint NOT NULL,
    queue_name character varying NOT NULL,
    created_at timestamp(6) with time zone NOT NULL
);


--
-- Name: solid_queue_pauses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_pauses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_pauses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_pauses_id_seq OWNED BY public.solid_queue_pauses.id;


--
-- Name: solid_queue_processes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_processes (
    id bigint NOT NULL,
    kind character varying NOT NULL,
    last_heartbeat_at timestamp(6) with time zone NOT NULL,
    supervisor_id bigint,
    pid integer NOT NULL,
    hostname character varying,
    metadata text,
    created_at timestamp(6) with time zone NOT NULL,
    name character varying NOT NULL
);


--
-- Name: solid_queue_processes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_processes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_processes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_processes_id_seq OWNED BY public.solid_queue_processes.id;


--
-- Name: solid_queue_ready_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_ready_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    queue_name character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL
);


--
-- Name: solid_queue_ready_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_ready_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_ready_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_ready_executions_id_seq OWNED BY public.solid_queue_ready_executions.id;


--
-- Name: solid_queue_recurring_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_recurring_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    task_key character varying NOT NULL,
    run_at timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL
);


--
-- Name: solid_queue_recurring_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_recurring_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_recurring_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_recurring_executions_id_seq OWNED BY public.solid_queue_recurring_executions.id;


--
-- Name: solid_queue_recurring_tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_recurring_tasks (
    id bigint NOT NULL,
    key character varying NOT NULL,
    schedule character varying NOT NULL,
    command character varying(2048),
    class_name character varying,
    arguments text,
    queue_name character varying,
    priority integer DEFAULT 0,
    static boolean DEFAULT true NOT NULL,
    description text,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: solid_queue_recurring_tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_recurring_tasks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_recurring_tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_recurring_tasks_id_seq OWNED BY public.solid_queue_recurring_tasks.id;


--
-- Name: solid_queue_scheduled_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_scheduled_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    queue_name character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    scheduled_at timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL
);


--
-- Name: solid_queue_scheduled_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_scheduled_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_scheduled_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_scheduled_executions_id_seq OWNED BY public.solid_queue_scheduled_executions.id;


--
-- Name: solid_queue_semaphores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_semaphores (
    id bigint NOT NULL,
    key character varying NOT NULL,
    value integer DEFAULT 1 NOT NULL,
    expires_at timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: solid_queue_semaphores_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_semaphores_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_semaphores_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_semaphores_id_seq OWNED BY public.solid_queue_semaphores.id;


--
-- Name: submission_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.submission_attempts (
    id bigint NOT NULL,
    order_proposal_id bigint NOT NULL,
    attempted_at timestamp(6) with time zone NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    response jsonb DEFAULT '{}'::jsonb NOT NULL,
    outcome character varying NOT NULL,
    reconciled_order_id bigint,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    broker_order_id character varying,
    reconciled_at timestamp with time zone,
    last_looked_at timestamp with time zone,
    last_look_could_see boolean,
    first_absence_at timestamp with time zone,
    ambiguous_order_ids jsonb DEFAULT '[]'::jsonb NOT NULL
);


--
-- Name: submission_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.submission_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: submission_attempts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.submission_attempts_id_seq OWNED BY public.submission_attempts.id;


--
-- Name: sync_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sync_runs (
    id bigint NOT NULL,
    feed character varying NOT NULL,
    status character varying NOT NULL,
    started_at timestamp(6) with time zone NOT NULL,
    finished_at timestamp(6) with time zone,
    error text,
    records_touched integer,
    unmapped_values jsonb DEFAULT '{}'::jsonb NOT NULL,
    window_from timestamp(6) with time zone,
    window_to timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    account_id bigint,
    gap_from timestamp(6) with time zone
);


--
-- Name: sync_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sync_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sync_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sync_runs_id_seq OWNED BY public.sync_runs.id;


--
-- Name: system_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_settings (
    id bigint NOT NULL,
    shadow_mode boolean DEFAULT true NOT NULL,
    manual_halt boolean DEFAULT false NOT NULL,
    manual_halt_reason text,
    manual_halt_at timestamp(6) with time zone,
    sync_paused_reason character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    rule_halt_rule character varying,
    rule_halt_reason character varying,
    rule_halt_tripped_at timestamp with time zone,
    rule_halt_resets_at timestamp with time zone,
    shadow_mode_changed_at timestamp with time zone,
    CONSTRAINT system_settings_singleton CHECK ((id = 1))
);


--
-- Name: system_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.system_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: system_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.system_settings_id_seq OWNED BY public.system_settings.id;


--
-- Name: tool_calls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_calls (
    id bigint NOT NULL,
    agent_run_id bigint,
    transport character varying NOT NULL,
    tool_name character varying NOT NULL,
    arguments jsonb DEFAULT '{}'::jsonb NOT NULL,
    duration_ms integer,
    error text,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: tool_calls_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tool_calls_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tool_calls_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tool_calls_id_seq OWNED BY public.tool_calls.id;


--
-- Name: trade_legs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trade_legs (
    id bigint NOT NULL,
    trade_id bigint NOT NULL,
    activity_id bigint,
    kind character varying NOT NULL,
    quantity numeric(18,6),
    price numeric(18,4),
    ratio numeric(12,6),
    cash_amount numeric(18,4),
    executed_at timestamp(6) with time zone,
    note character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: trade_legs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.trade_legs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: trade_legs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.trade_legs_id_seq OWNED BY public.trade_legs.id;


--
-- Name: trades; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trades (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    instrument_id bigint NOT NULL,
    setup_id bigint,
    order_proposal_id bigint,
    status character varying DEFAULT 'open'::character varying NOT NULL,
    needs_review boolean DEFAULT false NOT NULL,
    bootstrapped boolean DEFAULT false NOT NULL,
    opened_at timestamp(6) with time zone,
    closed_at timestamp(6) with time zone,
    avg_entry numeric(18,4),
    avg_exit numeric(18,4),
    peak_quantity numeric(18,6),
    planned_stop numeric(18,4),
    planned_target numeric(18,4),
    initial_risk numeric(18,4),
    realized_pnl numeric(18,4),
    realized_r numeric(10,4),
    thesis text,
    post_mortem text,
    followed_setup boolean,
    journal_completed_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    review_reason character varying,
    excluded_from_stats boolean DEFAULT false NOT NULL,
    stopped_out boolean DEFAULT false NOT NULL,
    initial_quantity numeric(18,6),
    total_risk numeric(18,4),
    quantity numeric(18,6) DEFAULT 0.0 NOT NULL,
    review_deferred_at timestamp(6) with time zone,
    agent_notes text
);


--
-- Name: trades_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.trades_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: trades_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.trades_id_seq OWNED BY public.trades.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email_address character varying NOT NULL,
    name character varying NOT NULL,
    magic_link_nonce character varying,
    last_login_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    approver boolean DEFAULT false NOT NULL,
    notify boolean DEFAULT false NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: watchlist_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.watchlist_items (
    id bigint NOT NULL,
    instrument_id bigint,
    symbol character varying NOT NULL,
    trigger text,
    thesis text,
    origin character varying NOT NULL,
    user_id bigint,
    status character varying DEFAULT 'watching'::character varying NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: watchlist_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.watchlist_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: watchlist_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.watchlist_items_id_seq OWNED BY public.watchlist_items.id;


--
-- Name: accounts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts ALTER COLUMN id SET DEFAULT nextval('public.accounts_id_seq'::regclass);


--
-- Name: activities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activities ALTER COLUMN id SET DEFAULT nextval('public.activities_id_seq'::regclass);


--
-- Name: agent_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs ALTER COLUMN id SET DEFAULT nextval('public.agent_runs_id_seq'::regclass);


--
-- Name: audit_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ALTER COLUMN id SET DEFAULT nextval('public.audit_events_id_seq'::regclass);


--
-- Name: balances id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.balances ALTER COLUMN id SET DEFAULT nextval('public.balances_id_seq'::regclass);


--
-- Name: devices id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices ALTER COLUMN id SET DEFAULT nextval('public.devices_id_seq'::regclass);


--
-- Name: instruments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.instruments ALTER COLUMN id SET DEFAULT nextval('public.instruments_id_seq'::regclass);


--
-- Name: market_days id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.market_days ALTER COLUMN id SET DEFAULT nextval('public.market_days_id_seq'::regclass);


--
-- Name: order_proposals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_proposals ALTER COLUMN id SET DEFAULT nextval('public.order_proposals_id_seq'::regclass);


--
-- Name: orders id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders ALTER COLUMN id SET DEFAULT nextval('public.orders_id_seq'::regclass);


--
-- Name: positions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.positions ALTER COLUMN id SET DEFAULT nextval('public.positions_id_seq'::regclass);


--
-- Name: risk_rules id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.risk_rules ALTER COLUMN id SET DEFAULT nextval('public.risk_rules_id_seq'::regclass);


--
-- Name: schwab_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schwab_tokens ALTER COLUMN id SET DEFAULT nextval('public.schwab_tokens_id_seq'::regclass);


--
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: setups id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.setups ALTER COLUMN id SET DEFAULT nextval('public.setups_id_seq'::regclass);


--
-- Name: snapshots id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.snapshots ALTER COLUMN id SET DEFAULT nextval('public.snapshots_id_seq'::regclass);


--
-- Name: solid_cable_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_cable_messages ALTER COLUMN id SET DEFAULT nextval('public.solid_cable_messages_id_seq'::regclass);


--
-- Name: solid_cache_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_cache_entries ALTER COLUMN id SET DEFAULT nextval('public.solid_cache_entries_id_seq'::regclass);


--
-- Name: solid_queue_batch_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batch_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_batch_executions_id_seq'::regclass);


--
-- Name: solid_queue_batches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batches ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_batches_id_seq'::regclass);


--
-- Name: solid_queue_blocked_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_blocked_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_blocked_executions_id_seq'::regclass);


--
-- Name: solid_queue_claimed_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_claimed_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_claimed_executions_id_seq'::regclass);


--
-- Name: solid_queue_failed_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_failed_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_failed_executions_id_seq'::regclass);


--
-- Name: solid_queue_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_jobs ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_jobs_id_seq'::regclass);


--
-- Name: solid_queue_pauses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_pauses ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_pauses_id_seq'::regclass);


--
-- Name: solid_queue_processes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_processes ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_processes_id_seq'::regclass);


--
-- Name: solid_queue_ready_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_ready_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_ready_executions_id_seq'::regclass);


--
-- Name: solid_queue_recurring_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_recurring_executions_id_seq'::regclass);


--
-- Name: solid_queue_recurring_tasks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_tasks ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_recurring_tasks_id_seq'::regclass);


--
-- Name: solid_queue_scheduled_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_scheduled_executions_id_seq'::regclass);


--
-- Name: solid_queue_semaphores id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_semaphores ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_semaphores_id_seq'::regclass);


--
-- Name: submission_attempts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.submission_attempts ALTER COLUMN id SET DEFAULT nextval('public.submission_attempts_id_seq'::regclass);


--
-- Name: sync_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_runs ALTER COLUMN id SET DEFAULT nextval('public.sync_runs_id_seq'::regclass);


--
-- Name: system_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_settings ALTER COLUMN id SET DEFAULT nextval('public.system_settings_id_seq'::regclass);


--
-- Name: tool_calls id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_calls ALTER COLUMN id SET DEFAULT nextval('public.tool_calls_id_seq'::regclass);


--
-- Name: trade_legs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trade_legs ALTER COLUMN id SET DEFAULT nextval('public.trade_legs_id_seq'::regclass);


--
-- Name: trades id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trades ALTER COLUMN id SET DEFAULT nextval('public.trades_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: watchlist_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchlist_items ALTER COLUMN id SET DEFAULT nextval('public.watchlist_items_id_seq'::regclass);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: activities activities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_pkey PRIMARY KEY (id);


--
-- Name: agent_runs agent_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs
    ADD CONSTRAINT agent_runs_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: balances balances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.balances
    ADD CONSTRAINT balances_pkey PRIMARY KEY (id);


--
-- Name: devices devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_pkey PRIMARY KEY (id);


--
-- Name: instruments instruments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.instruments
    ADD CONSTRAINT instruments_pkey PRIMARY KEY (id);


--
-- Name: market_days market_days_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.market_days
    ADD CONSTRAINT market_days_pkey PRIMARY KEY (id);


--
-- Name: order_proposals order_proposals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_proposals
    ADD CONSTRAINT order_proposals_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: positions positions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.positions
    ADD CONSTRAINT positions_pkey PRIMARY KEY (id);


--
-- Name: risk_rules risk_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.risk_rules
    ADD CONSTRAINT risk_rules_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: schwab_tokens schwab_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schwab_tokens
    ADD CONSTRAINT schwab_tokens_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: setups setups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.setups
    ADD CONSTRAINT setups_pkey PRIMARY KEY (id);


--
-- Name: snapshots snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.snapshots
    ADD CONSTRAINT snapshots_pkey PRIMARY KEY (id);


--
-- Name: solid_cable_messages solid_cable_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_cable_messages
    ADD CONSTRAINT solid_cable_messages_pkey PRIMARY KEY (id);


--
-- Name: solid_cache_entries solid_cache_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_cache_entries
    ADD CONSTRAINT solid_cache_entries_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_batch_executions solid_queue_batch_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batch_executions
    ADD CONSTRAINT solid_queue_batch_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_batches solid_queue_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batches
    ADD CONSTRAINT solid_queue_batches_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_blocked_executions solid_queue_blocked_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_blocked_executions
    ADD CONSTRAINT solid_queue_blocked_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_claimed_executions solid_queue_claimed_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_claimed_executions
    ADD CONSTRAINT solid_queue_claimed_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_failed_executions solid_queue_failed_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_failed_executions
    ADD CONSTRAINT solid_queue_failed_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_jobs solid_queue_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_jobs
    ADD CONSTRAINT solid_queue_jobs_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_pauses solid_queue_pauses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_pauses
    ADD CONSTRAINT solid_queue_pauses_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_processes solid_queue_processes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_processes
    ADD CONSTRAINT solid_queue_processes_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_ready_executions solid_queue_ready_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_ready_executions
    ADD CONSTRAINT solid_queue_ready_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_recurring_executions solid_queue_recurring_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_executions
    ADD CONSTRAINT solid_queue_recurring_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_recurring_tasks solid_queue_recurring_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_tasks
    ADD CONSTRAINT solid_queue_recurring_tasks_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_scheduled_executions solid_queue_scheduled_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions
    ADD CONSTRAINT solid_queue_scheduled_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_semaphores solid_queue_semaphores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_semaphores
    ADD CONSTRAINT solid_queue_semaphores_pkey PRIMARY KEY (id);


--
-- Name: submission_attempts submission_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.submission_attempts
    ADD CONSTRAINT submission_attempts_pkey PRIMARY KEY (id);


--
-- Name: sync_runs sync_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_runs
    ADD CONSTRAINT sync_runs_pkey PRIMARY KEY (id);


--
-- Name: system_settings system_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_settings
    ADD CONSTRAINT system_settings_pkey PRIMARY KEY (id);


--
-- Name: tool_calls tool_calls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_calls
    ADD CONSTRAINT tool_calls_pkey PRIMARY KEY (id);


--
-- Name: trade_legs trade_legs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trade_legs
    ADD CONSTRAINT trade_legs_pkey PRIMARY KEY (id);


--
-- Name: trades trades_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trades
    ADD CONSTRAINT trades_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: watchlist_items watchlist_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchlist_items
    ADD CONSTRAINT watchlist_items_pkey PRIMARY KEY (id);


--
-- Name: idx_on_account_id_instrument_id_executed_at_dd9c0c3d68; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_id_instrument_id_executed_at_dd9c0c3d68 ON public.activities USING btree (account_id, instrument_id, executed_at);


--
-- Name: index_accounts_on_schwab_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_accounts_on_schwab_hash ON public.accounts USING btree (schwab_hash);


--
-- Name: index_activities_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_activities_on_account_id ON public.activities USING btree (account_id);


--
-- Name: index_activities_on_account_id_and_broker_activity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_activities_on_account_id_and_broker_activity_id ON public.activities USING btree (account_id, broker_activity_id);


--
-- Name: index_activities_on_instrument_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_activities_on_instrument_id ON public.activities USING btree (instrument_id);


--
-- Name: index_activities_on_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_activities_on_kind ON public.activities USING btree (kind);


--
-- Name: index_activities_on_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_activities_on_order_id ON public.activities USING btree (order_id);


--
-- Name: index_activities_unjournaled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_activities_unjournaled ON public.activities USING btree (id) WHERE (journaled_at IS NULL);


--
-- Name: index_agent_runs_on_kind_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_kind_and_created_at ON public.agent_runs USING btree (kind, created_at);


--
-- Name: index_agent_runs_on_started_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_started_at ON public.agent_runs USING btree (started_at);


--
-- Name: index_agent_runs_one_per_kind_and_day; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_runs_one_per_kind_and_day ON public.agent_runs USING btree (kind, market_date) WHERE ((status)::text <> 'failed'::text);


--
-- Name: index_audit_events_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_created_at ON public.audit_events USING btree (created_at);


--
-- Name: index_audit_events_on_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_kind ON public.audit_events USING btree (kind);


--
-- Name: index_audit_events_on_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_subject ON public.audit_events USING btree (subject_type, subject_id);


--
-- Name: index_audit_events_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_user_id ON public.audit_events USING btree (user_id);


--
-- Name: index_balances_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_balances_on_account_id ON public.balances USING btree (account_id);


--
-- Name: index_balances_on_account_id_and_as_of; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_balances_on_account_id_and_as_of ON public.balances USING btree (account_id, as_of);


--
-- Name: index_devices_on_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_devices_on_token ON public.devices USING btree (token);


--
-- Name: index_devices_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_devices_on_user_id ON public.devices USING btree (user_id);


--
-- Name: index_instruments_on_cusip; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_instruments_on_cusip ON public.instruments USING btree (cusip) WHERE (cusip IS NOT NULL);


--
-- Name: index_instruments_on_predecessor_instrument_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_instruments_on_predecessor_instrument_id ON public.instruments USING btree (predecessor_instrument_id);


--
-- Name: index_instruments_on_schwab_instrument_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_instruments_on_schwab_instrument_id ON public.instruments USING btree (schwab_instrument_id) WHERE (schwab_instrument_id IS NOT NULL);


--
-- Name: index_instruments_on_symbol; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_instruments_on_symbol ON public.instruments USING btree (symbol);


--
-- Name: index_instruments_provisional; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_instruments_provisional ON public.instruments USING btree (symbol, asset_type) WHERE ((cusip IS NULL) AND (schwab_instrument_id IS NULL));


--
-- Name: index_market_days_on_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_market_days_on_date ON public.market_days USING btree (date);


--
-- Name: index_order_proposals_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_order_proposals_on_account_id ON public.order_proposals USING btree (account_id);


--
-- Name: index_order_proposals_on_broker_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_order_proposals_on_broker_order_id ON public.order_proposals USING btree (broker_order_id) WHERE (broker_order_id IS NOT NULL);


--
-- Name: index_order_proposals_on_decided_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_order_proposals_on_decided_by_id ON public.order_proposals USING btree (decided_by_id);


--
-- Name: index_order_proposals_on_instrument_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_order_proposals_on_instrument_id ON public.order_proposals USING btree (instrument_id);


--
-- Name: index_order_proposals_on_parent_proposal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_order_proposals_on_parent_proposal_id ON public.order_proposals USING btree (parent_proposal_id);


--
-- Name: index_order_proposals_on_setup_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_order_proposals_on_setup_id ON public.order_proposals USING btree (setup_id);


--
-- Name: index_order_proposals_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_order_proposals_on_status ON public.order_proposals USING btree (status);


--
-- Name: index_order_proposals_on_target_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_order_proposals_on_target_order_id ON public.order_proposals USING btree (target_order_id);


--
-- Name: index_order_proposals_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_order_proposals_on_user_id ON public.order_proposals USING btree (user_id);


--
-- Name: index_order_proposals_one_open_per_instrument_and_side; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_order_proposals_one_open_per_instrument_and_side ON public.order_proposals USING btree (account_id, instrument_id, side) WHERE ((status)::text = ANY (ARRAY[('proposed'::character varying)::text, ('validated'::character varying)::text]));


--
-- Name: index_order_proposals_one_unresolved_per_instrument; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_order_proposals_one_unresolved_per_instrument ON public.order_proposals USING btree (account_id, instrument_id) WHERE ((status)::text = ANY (ARRAY[('submitting'::character varying)::text, ('submission_unknown'::character varying)::text]));


--
-- Name: index_orders_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_on_account_id ON public.orders USING btree (account_id);


--
-- Name: index_orders_on_account_id_and_broker_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_orders_on_account_id_and_broker_order_id ON public.orders USING btree (account_id, broker_order_id);


--
-- Name: index_orders_on_account_id_and_instrument_id_and_entered_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_on_account_id_and_instrument_id_and_entered_at ON public.orders USING btree (account_id, instrument_id, entered_at);


--
-- Name: index_orders_on_account_id_and_instrument_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_on_account_id_and_instrument_id_and_status ON public.orders USING btree (account_id, instrument_id, status);


--
-- Name: index_orders_on_instrument_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_on_instrument_id ON public.orders USING btree (instrument_id);


--
-- Name: index_orders_on_order_proposal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_on_order_proposal_id ON public.orders USING btree (order_proposal_id);


--
-- Name: index_orders_on_parent_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_on_parent_order_id ON public.orders USING btree (parent_order_id);


--
-- Name: index_orders_on_replaces_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_on_replaces_order_id ON public.orders USING btree (replaces_order_id);


--
-- Name: index_positions_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_positions_on_account_id ON public.positions USING btree (account_id);


--
-- Name: index_positions_on_account_id_and_instrument_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_positions_on_account_id_and_instrument_id ON public.positions USING btree (account_id, instrument_id);


--
-- Name: index_positions_on_instrument_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_positions_on_instrument_id ON public.positions USING btree (instrument_id);


--
-- Name: index_positions_on_working_stop_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_positions_on_working_stop_order_id ON public.positions USING btree (working_stop_order_id);


--
-- Name: index_risk_rules_on_changed_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_risk_rules_on_changed_by_id ON public.risk_rules USING btree (changed_by_id);


--
-- Name: index_risk_rules_on_setup_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_risk_rules_on_setup_id ON public.risk_rules USING btree (setup_id);


--
-- Name: index_risk_rules_on_superseded_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_risk_rules_on_superseded_by_id ON public.risk_rules USING btree (superseded_by_id);


--
-- Name: index_risk_rules_one_active_per_type_and_setup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_risk_rules_one_active_per_type_and_setup ON public.risk_rules USING btree (rule_type, setup_id) NULLS NOT DISTINCT WHERE active;


--
-- Name: index_schwab_tokens_on_issued_at_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_schwab_tokens_on_issued_at_and_id ON public.schwab_tokens USING btree (issued_at DESC, id DESC);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_setups_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_setups_on_name ON public.setups USING btree (name);


--
-- Name: index_snapshots_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_snapshots_on_account_id ON public.snapshots USING btree (account_id);


--
-- Name: index_snapshots_on_account_id_and_as_of; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_snapshots_on_account_id_and_as_of ON public.snapshots USING btree (account_id, as_of);


--
-- Name: index_solid_cable_messages_on_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cable_messages_on_channel ON public.solid_cable_messages USING btree (channel);


--
-- Name: index_solid_cable_messages_on_channel_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cable_messages_on_channel_hash ON public.solid_cable_messages USING btree (channel_hash);


--
-- Name: index_solid_cable_messages_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cable_messages_on_created_at ON public.solid_cable_messages USING btree (created_at);


--
-- Name: index_solid_cache_entries_on_byte_size; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cache_entries_on_byte_size ON public.solid_cache_entries USING btree (byte_size);


--
-- Name: index_solid_cache_entries_on_key_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_cache_entries_on_key_hash ON public.solid_cache_entries USING btree (key_hash);


--
-- Name: index_solid_cache_entries_on_key_hash_and_byte_size; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cache_entries_on_key_hash_and_byte_size ON public.solid_cache_entries USING btree (key_hash, byte_size);


--
-- Name: index_solid_queue_batch_executions_on_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_batch_executions_on_batch_id ON public.solid_queue_batch_executions USING btree (batch_id);


--
-- Name: index_solid_queue_batch_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_batch_executions_on_job_id ON public.solid_queue_batch_executions USING btree (job_id);


--
-- Name: index_solid_queue_batches_on_active_job_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_batches_on_active_job_batch_id ON public.solid_queue_batches USING btree (active_job_batch_id);


--
-- Name: index_solid_queue_batches_on_finished_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_batches_on_finished_at ON public.solid_queue_batches USING btree (finished_at);


--
-- Name: index_solid_queue_blocked_executions_for_maintenance; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_blocked_executions_for_maintenance ON public.solid_queue_blocked_executions USING btree (expires_at, concurrency_key);


--
-- Name: index_solid_queue_blocked_executions_for_release; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_blocked_executions_for_release ON public.solid_queue_blocked_executions USING btree (concurrency_key, priority, job_id);


--
-- Name: index_solid_queue_blocked_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_blocked_executions_on_job_id ON public.solid_queue_blocked_executions USING btree (job_id);


--
-- Name: index_solid_queue_claimed_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_claimed_executions_on_job_id ON public.solid_queue_claimed_executions USING btree (job_id);


--
-- Name: index_solid_queue_claimed_executions_on_process_id_and_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_claimed_executions_on_process_id_and_job_id ON public.solid_queue_claimed_executions USING btree (process_id, job_id);


--
-- Name: index_solid_queue_dispatch_all; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_dispatch_all ON public.solid_queue_scheduled_executions USING btree (scheduled_at, priority, job_id);


--
-- Name: index_solid_queue_failed_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_failed_executions_on_job_id ON public.solid_queue_failed_executions USING btree (job_id);


--
-- Name: index_solid_queue_jobs_for_alerting; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_for_alerting ON public.solid_queue_jobs USING btree (scheduled_at, finished_at);


--
-- Name: index_solid_queue_jobs_for_filtering; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_for_filtering ON public.solid_queue_jobs USING btree (queue_name, finished_at);


--
-- Name: index_solid_queue_jobs_on_active_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_active_job_id ON public.solid_queue_jobs USING btree (active_job_id);


--
-- Name: index_solid_queue_jobs_on_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_batch_id ON public.solid_queue_jobs USING btree (batch_id);


--
-- Name: index_solid_queue_jobs_on_class_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_class_name ON public.solid_queue_jobs USING btree (class_name);


--
-- Name: index_solid_queue_jobs_on_finished_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_finished_at ON public.solid_queue_jobs USING btree (finished_at);


--
-- Name: index_solid_queue_pauses_on_queue_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_pauses_on_queue_name ON public.solid_queue_pauses USING btree (queue_name);


--
-- Name: index_solid_queue_poll_all; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_poll_all ON public.solid_queue_ready_executions USING btree (priority, job_id);


--
-- Name: index_solid_queue_poll_by_queue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_poll_by_queue ON public.solid_queue_ready_executions USING btree (queue_name, priority, job_id);


--
-- Name: index_solid_queue_processes_on_last_heartbeat_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_processes_on_last_heartbeat_at ON public.solid_queue_processes USING btree (last_heartbeat_at);


--
-- Name: index_solid_queue_processes_on_name_and_supervisor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_processes_on_name_and_supervisor_id ON public.solid_queue_processes USING btree (name, supervisor_id);


--
-- Name: index_solid_queue_processes_on_supervisor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_processes_on_supervisor_id ON public.solid_queue_processes USING btree (supervisor_id);


--
-- Name: index_solid_queue_ready_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_ready_executions_on_job_id ON public.solid_queue_ready_executions USING btree (job_id);


--
-- Name: index_solid_queue_recurring_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_recurring_executions_on_job_id ON public.solid_queue_recurring_executions USING btree (job_id);


--
-- Name: index_solid_queue_recurring_executions_on_task_key_and_run_at; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_recurring_executions_on_task_key_and_run_at ON public.solid_queue_recurring_executions USING btree (task_key, run_at);


--
-- Name: index_solid_queue_recurring_tasks_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_recurring_tasks_on_key ON public.solid_queue_recurring_tasks USING btree (key);


--
-- Name: index_solid_queue_recurring_tasks_on_static; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_recurring_tasks_on_static ON public.solid_queue_recurring_tasks USING btree (static);


--
-- Name: index_solid_queue_scheduled_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_scheduled_executions_on_job_id ON public.solid_queue_scheduled_executions USING btree (job_id);


--
-- Name: index_solid_queue_semaphores_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_semaphores_on_expires_at ON public.solid_queue_semaphores USING btree (expires_at);


--
-- Name: index_solid_queue_semaphores_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_semaphores_on_key ON public.solid_queue_semaphores USING btree (key);


--
-- Name: index_solid_queue_semaphores_on_key_and_value; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_semaphores_on_key_and_value ON public.solid_queue_semaphores USING btree (key, value);


--
-- Name: index_submission_attempts_on_order_proposal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_submission_attempts_on_order_proposal_id ON public.submission_attempts USING btree (order_proposal_id);


--
-- Name: index_submission_attempts_on_reconciled_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_submission_attempts_on_reconciled_order_id ON public.submission_attempts USING btree (reconciled_order_id);


--
-- Name: index_submission_attempts_one_live_per_proposal; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_submission_attempts_one_live_per_proposal ON public.submission_attempts USING btree (order_proposal_id) WHERE ((outcome)::text <> ALL (ARRAY[('failed'::character varying)::text, ('not_placed'::character varying)::text]));


--
-- Name: index_sync_runs_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sync_runs_on_account_id ON public.sync_runs USING btree (account_id);


--
-- Name: index_sync_runs_on_feed_and_started_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sync_runs_on_feed_and_started_at ON public.sync_runs USING btree (feed, started_at);


--
-- Name: index_tool_calls_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tool_calls_on_agent_run_id ON public.tool_calls USING btree (agent_run_id);


--
-- Name: index_tool_calls_on_tool_name_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tool_calls_on_tool_name_and_created_at ON public.tool_calls USING btree (tool_name, created_at);


--
-- Name: index_trade_legs_on_activity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_trade_legs_on_activity_id ON public.trade_legs USING btree (activity_id) WHERE (activity_id IS NOT NULL);


--
-- Name: index_trade_legs_on_trade_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trade_legs_on_trade_id ON public.trade_legs USING btree (trade_id);


--
-- Name: index_trades_needing_review; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trades_needing_review ON public.trades USING btree (id) WHERE needs_review;


--
-- Name: index_trades_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trades_on_account_id ON public.trades USING btree (account_id);


--
-- Name: index_trades_on_account_id_and_instrument_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trades_on_account_id_and_instrument_id_and_status ON public.trades USING btree (account_id, instrument_id, status);


--
-- Name: index_trades_on_instrument_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trades_on_instrument_id ON public.trades USING btree (instrument_id);


--
-- Name: index_trades_on_order_proposal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_trades_on_order_proposal_id ON public.trades USING btree (order_proposal_id);


--
-- Name: index_trades_on_setup_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trades_on_setup_id ON public.trades USING btree (setup_id);


--
-- Name: index_trades_one_open_per_instrument; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_trades_one_open_per_instrument ON public.trades USING btree (account_id, instrument_id) WHERE ((status)::text = 'open'::text);


--
-- Name: index_users_on_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email_address ON public.users USING btree (email_address);


--
-- Name: index_watchlist_items_on_instrument_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_watchlist_items_on_instrument_id ON public.watchlist_items USING btree (instrument_id);


--
-- Name: index_watchlist_items_on_symbol_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_watchlist_items_on_symbol_and_status ON public.watchlist_items USING btree (symbol, status);


--
-- Name: index_watchlist_items_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_watchlist_items_on_user_id ON public.watchlist_items USING btree (user_id);


--
-- Name: index_watchlist_items_one_watching_per_symbol; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_watchlist_items_one_watching_per_symbol ON public.watchlist_items USING btree (symbol) WHERE ((status)::text = 'watching'::text);


--
-- Name: audit_events audit_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_events_append_only BEFORE DELETE OR UPDATE ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.audit_events_append_only();


--
-- Name: audit_events audit_events_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_events_no_truncate BEFORE TRUNCATE ON public.audit_events FOR EACH STATEMENT EXECUTE FUNCTION public.audit_events_append_only();


--
-- Name: watchlist_items fk_rails_077cf8f283; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchlist_items
    ADD CONSTRAINT fk_rails_077cf8f283 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: instruments fk_rails_0a8f1c5db0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.instruments
    ADD CONSTRAINT fk_rails_0a8f1c5db0 FOREIGN KEY (predecessor_instrument_id) REFERENCES public.instruments(id);


--
-- Name: orders fk_rails_0acd2a4d14; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT fk_rails_0acd2a4d14 FOREIGN KEY (replaces_order_id) REFERENCES public.orders(id);


--
-- Name: orders fk_rails_144e25bef6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT fk_rails_144e25bef6 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: positions fk_rails_2adf75f9a8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.positions
    ADD CONSTRAINT fk_rails_2adf75f9a8 FOREIGN KEY (instrument_id) REFERENCES public.instruments(id);


--
-- Name: solid_queue_recurring_executions fk_rails_318a5533ed; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_executions
    ADD CONSTRAINT fk_rails_318a5533ed FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: solid_queue_failed_executions fk_rails_39bbc7a631; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_failed_executions
    ADD CONSTRAINT fk_rails_39bbc7a631 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: trades fk_rails_3dd8f3515d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trades
    ADD CONSTRAINT fk_rails_3dd8f3515d FOREIGN KEY (setup_id) REFERENCES public.setups(id);


--
-- Name: devices fk_rails_410b63ef65; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT fk_rails_410b63ef65 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: risk_rules fk_rails_48618bfc42; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.risk_rules
    ADD CONSTRAINT fk_rails_48618bfc42 FOREIGN KEY (changed_by_id) REFERENCES public.users(id);


--
-- Name: snapshots fk_rails_4c1abcd194; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.snapshots
    ADD CONSTRAINT fk_rails_4c1abcd194 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: positions fk_rails_4ccd9a0798; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.positions
    ADD CONSTRAINT fk_rails_4ccd9a0798 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: solid_queue_blocked_executions fk_rails_4cd34e2228; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_blocked_executions
    ADD CONSTRAINT fk_rails_4cd34e2228 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: submission_attempts fk_rails_4f4bcc6ff0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.submission_attempts
    ADD CONSTRAINT fk_rails_4f4bcc6ff0 FOREIGN KEY (reconciled_order_id) REFERENCES public.orders(id);


--
-- Name: activities fk_rails_6886e9a52a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT fk_rails_6886e9a52a FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: order_proposals fk_rails_73202120c3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_proposals
    ADD CONSTRAINT fk_rails_73202120c3 FOREIGN KEY (instrument_id) REFERENCES public.instruments(id);


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: trades fk_rails_759807f5a3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trades
    ADD CONSTRAINT fk_rails_759807f5a3 FOREIGN KEY (order_proposal_id) REFERENCES public.order_proposals(id);


--
-- Name: orders fk_rails_7c21493c68; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT fk_rails_7c21493c68 FOREIGN KEY (instrument_id) REFERENCES public.instruments(id);


--
-- Name: solid_queue_batch_executions fk_rails_7c5e073422; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batch_executions
    ADD CONSTRAINT fk_rails_7c5e073422 FOREIGN KEY (batch_id) REFERENCES public.solid_queue_batches(id) ON DELETE CASCADE;


--
-- Name: solid_queue_ready_executions fk_rails_81fcbd66af; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_ready_executions
    ADD CONSTRAINT fk_rails_81fcbd66af FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: orders fk_rails_830e3b7893; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT fk_rails_830e3b7893 FOREIGN KEY (order_proposal_id) REFERENCES public.order_proposals(id);


--
-- Name: watchlist_items fk_rails_85e9763357; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchlist_items
    ADD CONSTRAINT fk_rails_85e9763357 FOREIGN KEY (instrument_id) REFERENCES public.instruments(id);


--
-- Name: balances fk_rails_9452e1f8fd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.balances
    ADD CONSTRAINT fk_rails_9452e1f8fd FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: solid_queue_claimed_executions fk_rails_9cfe4d4944; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_claimed_executions
    ADD CONSTRAINT fk_rails_9cfe4d4944 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: activities fk_rails_a922258fa9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT fk_rails_a922258fa9 FOREIGN KEY (instrument_id) REFERENCES public.instruments(id);


--
-- Name: trades fk_rails_abc1443ac4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trades
    ADD CONSTRAINT fk_rails_abc1443ac4 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: order_proposals fk_rails_af52bf430e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_proposals
    ADD CONSTRAINT fk_rails_af52bf430e FOREIGN KEY (target_order_id) REFERENCES public.orders(id);


--
-- Name: risk_rules fk_rails_b11befadb1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.risk_rules
    ADD CONSTRAINT fk_rails_b11befadb1 FOREIGN KEY (superseded_by_id) REFERENCES public.risk_rules(id);


--
-- Name: trade_legs fk_rails_b361f1f1f1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trade_legs
    ADD CONSTRAINT fk_rails_b361f1f1f1 FOREIGN KEY (activity_id) REFERENCES public.activities(id);


--
-- Name: risk_rules fk_rails_b90282de46; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.risk_rules
    ADD CONSTRAINT fk_rails_b90282de46 FOREIGN KEY (setup_id) REFERENCES public.setups(id);


--
-- Name: solid_queue_batch_executions fk_rails_bc9f981155; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batch_executions
    ADD CONSTRAINT fk_rails_bc9f981155 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: sync_runs fk_rails_bd20a3f65b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_runs
    ADD CONSTRAINT fk_rails_bd20a3f65b FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: order_proposals fk_rails_bfa8882b3a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_proposals
    ADD CONSTRAINT fk_rails_bfa8882b3a FOREIGN KEY (decided_by_id) REFERENCES public.users(id);


--
-- Name: order_proposals fk_rails_c0ae416341; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_proposals
    ADD CONSTRAINT fk_rails_c0ae416341 FOREIGN KEY (parent_proposal_id) REFERENCES public.order_proposals(id);


--
-- Name: trades fk_rails_c19f3a5dfc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trades
    ADD CONSTRAINT fk_rails_c19f3a5dfc FOREIGN KEY (instrument_id) REFERENCES public.instruments(id);


--
-- Name: solid_queue_scheduled_executions fk_rails_c4316f352d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions
    ADD CONSTRAINT fk_rails_c4316f352d FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: order_proposals fk_rails_c925fe9588; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_proposals
    ADD CONSTRAINT fk_rails_c925fe9588 FOREIGN KEY (setup_id) REFERENCES public.setups(id);


--
-- Name: tool_calls fk_rails_cc11d0226e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_calls
    ADD CONSTRAINT fk_rails_cc11d0226e FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id);


--
-- Name: audit_events fk_rails_d27dff91d1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_d27dff91d1 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: submission_attempts fk_rails_d2c6c378ee; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.submission_attempts
    ADD CONSTRAINT fk_rails_d2c6c378ee FOREIGN KEY (order_proposal_id) REFERENCES public.order_proposals(id);


--
-- Name: activities fk_rails_e53101708c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT fk_rails_e53101708c FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: positions fk_rails_e6858896be; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.positions
    ADD CONSTRAINT fk_rails_e6858896be FOREIGN KEY (working_stop_order_id) REFERENCES public.orders(id);


--
-- Name: order_proposals fk_rails_ea7b5f70bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_proposals
    ADD CONSTRAINT fk_rails_ea7b5f70bd FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: orders fk_rails_f5d8121a45; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT fk_rails_f5d8121a45 FOREIGN KEY (parent_order_id) REFERENCES public.orders(id);


--
-- Name: trade_legs fk_rails_fb47c7025b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trade_legs
    ADD CONSTRAINT fk_rails_fb47c7025b FOREIGN KEY (trade_id) REFERENCES public.trades(id);


--
-- Name: order_proposals fk_rails_fcc1bd776c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_proposals
    ADD CONSTRAINT fk_rails_fcc1bd776c FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260902200001'),
('20260902190001'),
('20260902180001'),
('20260902170001'),
('20260902160001'),
('20260902150001'),
('20260902140001'),
('20260902130001'),
('20260902120001'),
('20260902110001'),
('20260902100001'),
('20260901260001'),
('20260901250001'),
('20260901240003'),
('20260901240002'),
('20260901240001'),
('20260901230001'),
('20260901220020'),
('20260901220019'),
('20260901220018'),
('20260901220017'),
('20260901220016'),
('20260901220015'),
('20260901220014'),
('20260901220013'),
('20260901220012'),
('20260901220011'),
('20260901220010'),
('20260901220009'),
('20260901220008'),
('20260901220007'),
('20260901220006'),
('20260901220005'),
('20260901220004'),
('20260901220003'),
('20260901220002'),
('20260901220001'),
('20260901212454'),
('20260901212453');

