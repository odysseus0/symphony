defmodule SymphonyElixir.RateLimitCircuitBreaker do
  @moduledoc """
  Detects rate-limit signals in agent session output/errors and manages
  per-runtime circuit breakers so the orchestrator stops dispatching
  to a rate-limited backend until the cooldown expires.
  """

  require Logger

  @default_cooldown_ms 5 * 60 * 1_000

  @rate_limit_patterns [
    "hit your limit",
    "rate limit",
    "429",
    "quota exceeded",
    "resets at",
    "try again later"
  ]

  # ── Detection ──────────────────────────────────────────────────────────────

  @doc """
  Returns `true` when the text contains any known rate-limit indicator.
  """
  @spec rate_limit_detected?(term()) :: boolean()
  def rate_limit_detected?(text) when is_binary(text) do
    downcased = String.downcase(text)
    Enum.any?(@rate_limit_patterns, &String.contains?(downcased, &1))
  end

  def rate_limit_detected?(reason) do
    reason
    |> inspect(pretty: false, printable_limit: 8_000, limit: 100)
    |> rate_limit_detected?()
  end

  # ── Reset-time parsing ────────────────────────────────────────────────────

  @doc """
  Attempts to extract a reset timestamp from a rate-limit message and returns
  the cooldown in milliseconds.  Falls back to `@default_cooldown_ms`.

  Recognised patterns:
    - "resets 5pm"  /  "resets 17:00"  (interpreted in the system's local timezone)
    - "resets 5pm (Asia/Shanghai)"     (explicit timezone — timezone string is noted but
       we compute the delta using system-local time for simplicity)
    - "retry after 300"  /  "retry-after: 120"  (seconds)
  """
  @spec cooldown_ms(String.t()) :: non_neg_integer()
  def cooldown_ms(text) when is_binary(text) do
    downcased = String.downcase(text)

    cond do
      (seconds = parse_retry_after_seconds(downcased)) != nil ->
        max(seconds * 1_000, 0)

      (reset_ms = parse_resets_at_time(downcased)) != nil ->
        max(reset_ms, 0)

      true ->
        @default_cooldown_ms
    end
  end

  def cooldown_ms(_text), do: @default_cooldown_ms

  @doc "Returns the default cooldown in milliseconds."
  @spec default_cooldown_ms() :: non_neg_integer()
  def default_cooldown_ms, do: @default_cooldown_ms

  # ── Circuit breaker state helpers ─────────────────────────────────────────

  @typedoc "A single circuit breaker entry."
  @type breaker_entry :: %{
          tripped_at_ms: integer(),
          expires_at_ms: integer(),
          reason_snippet: String.t()
        }

  @typedoc "Map of runtime_name → breaker_entry."
  @type breakers :: %{optional(String.t()) => breaker_entry()}

  @doc """
  Trip the circuit breaker for `runtime_name`.  Returns the updated breakers map.
  """
  @spec trip(breakers(), String.t(), non_neg_integer(), String.t()) :: breakers()
  def trip(breakers, runtime_name, cooldown, reason_snippet)
      when is_map(breakers) and is_binary(runtime_name) and is_integer(cooldown) do
    now_ms = System.monotonic_time(:millisecond)

    entry = %{
      tripped_at_ms: now_ms,
      expires_at_ms: now_ms + cooldown,
      reason_snippet: truncate(reason_snippet, 200)
    }

    Logger.warning(
      "Circuit breaker TRIPPED for runtime=#{runtime_name} cooldown_ms=#{cooldown} reason=#{entry.reason_snippet}"
    )

    Map.put(breakers, runtime_name, entry)
  end

  @doc """
  Returns `true` when the runtime is currently circuit-broken (breaker tripped
  and cooldown has not yet expired).
  """
  @spec open?(breakers(), String.t()) :: boolean()
  def open?(breakers, runtime_name) when is_map(breakers) and is_binary(runtime_name) do
    case Map.get(breakers, runtime_name) do
      %{expires_at_ms: expires_at_ms} ->
        System.monotonic_time(:millisecond) < expires_at_ms

      _ ->
        false
    end
  end

  @doc """
  Remove expired breaker entries and log recovery.  Returns the pruned map.
  """
  @spec expire_recovered(breakers()) :: breakers()
  def expire_recovered(breakers) when is_map(breakers) do
    now_ms = System.monotonic_time(:millisecond)

    {expired, active} =
      Enum.split_with(breakers, fn {_name, %{expires_at_ms: exp}} -> now_ms >= exp end)

    Enum.each(expired, fn {name, _entry} ->
      Logger.info("Circuit breaker RECOVERED for runtime=#{name}")
    end)

    Map.new(active)
  end

  # ── Convenience: detect + trip in one step ────────────────────────────────

  @doc """
  Inspect a session's exit reason (or output text) and, if it looks like a
  rate-limit, trip the breaker for the given runtime.  Returns `{tripped?, breakers}`.
  """
  @spec maybe_trip(breakers(), String.t() | nil, term()) :: {boolean(), breakers()}
  def maybe_trip(breakers, nil, _reason), do: {false, breakers}

  def maybe_trip(breakers, runtime_name, reason) do
    reason_text = normalize_reason_text(reason)

    if rate_limit_detected?(reason_text) do
      cooldown = cooldown_ms(reason_text)
      {true, trip(breakers, runtime_name, cooldown, reason_text)}
    else
      {false, breakers}
    end
  end

  # ── Internal helpers ──────────────────────────────────────────────────────

  defp normalize_reason_text(text) when is_binary(text), do: text

  defp normalize_reason_text(reason) do
    reason
    |> inspect(pretty: false, printable_limit: 8_000, limit: 100)
  end

  # "retry after 300", "retry-after: 120"
  defp parse_retry_after_seconds(text) do
    case Regex.run(~r/retry[\s\-]*after[\s:]*(\d+)/i, text) do
      [_, seconds_str] ->
        case Integer.parse(seconds_str) do
          {seconds, _} when seconds > 0 -> seconds
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # "resets 5pm", "resets 17:00", "resets 5pm (Asia/Shanghai)"
  defp parse_resets_at_time(text) do
    cond do
      # "resets <H>pm" or "resets <H>am"
      (match = Regex.run(~r/resets?\s+(\d{1,2})\s*(am|pm)/i, text)) != nil ->
        [_, hour_str, ampm] = match
        hour_24 = to_24h(String.to_integer(hour_str), String.downcase(ampm))
        ms_until_hour(hour_24, 0)

      # "resets <HH>:<MM>"
      (match = Regex.run(~r/resets?\s+(\d{1,2}):(\d{2})/i, text)) != nil ->
        [_, hour_str, min_str] = match
        ms_until_hour(String.to_integer(hour_str), String.to_integer(min_str))

      true ->
        nil
    end
  end

  defp to_24h(12, "am"), do: 0
  defp to_24h(12, "pm"), do: 12
  defp to_24h(hour, "pm"), do: hour + 12
  defp to_24h(hour, "am"), do: hour

  defp ms_until_hour(target_hour, target_min) do
    {_date, {h, min, s}} = :calendar.local_time()

    target_seconds = target_hour * 3600 + target_min * 60
    current_seconds = h * 3600 + min * 60 + s

    delta_seconds =
      if target_seconds > current_seconds do
        target_seconds - current_seconds
      else
        # Target is tomorrow
        target_seconds + 86_400 - current_seconds
      end

    # Sanity cap: never exceed 24 hours
    min(delta_seconds * 1_000, 86_400_000)
  end

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max - 3) <> "..."
  end

  defp truncate(text, _max), do: text
end
