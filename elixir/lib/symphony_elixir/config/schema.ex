defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
      # Plane-specific fields
      field(:workspace_slug, :string)
      field(:project_id, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :api_key, :project_slug, :assignee, :active_states, :terminal_states,
         :workspace_slug, :project_id],
        empty_values: []
      )
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
      field(:cleanup_keep_recent, :integer, default: 5)
      field(:warning_threshold_bytes, :integer, default: 10 * 1024 * 1024 * 1024)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root, :cleanup_keep_recent, :warning_threshold_bytes], empty_values: [])
      |> validate_number(:cleanup_keep_recent, greater_than_or_equal_to: 0)
      |> validate_number(:warning_threshold_bytes, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:backend, :string, default: "codex")
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:backend, :max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state],
        empty_values: []
      )
      |> validate_required([:backend])
      |> validate_length(:backend, min: 1)
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Runtime do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:name, :string)
      field(:command, :string, default: "codex app-server")
      field(:labels, {:array, :string}, default: [])
      field(:max_turns, :integer)

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :name,
          :command,
          :labels,
          :max_turns,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:name, :command])
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule BackendEntry do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:name, :string)
      field(:adapter, :string)
      field(:command, :string)
      field(:approval_policy, StringOrMap)
      field(:thread_sandbox, :string)
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer)
      field(:read_timeout_ms, :integer)
      field(:stall_timeout_ms, :integer)
      field(:permission_mode, :string)
      field(:model, :string)
      field(:mcp_tools, :boolean)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :name,
          :adapter,
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms,
          :permission_mode,
          :model,
          :mcp_tools
        ],
        empty_values: []
      )
      |> validate_required([:name, :command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Backends do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:default, :string, default: "codex")
      embeds_many(:entries, BackendEntry, on_replace: :delete)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:default], empty_values: [])
      |> validate_required([:default])
      |> cast_embed(:entries, with: &BackendEntry.changeset/2)
    end
  end

  defmodule Routing do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:labels, :map, default: %{})
      field(:fallback, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:labels, :fallback], empty_values: [])
      |> validate_change(:labels, fn :labels, labels ->
        cond do
          is_nil(labels) ->
            []

          not is_map(labels) ->
            [labels: "must be a map of label to backend name"]

          true ->
            Enum.flat_map(labels, fn {label, backend_name} ->
              cond do
                to_string(label) == "" ->
                  [labels: "labels must not include blank keys"]

                not is_binary(backend_name) ->
                  [labels: "routing labels must reference backend names as strings"]

                String.trim(backend_name) == "" ->
                  [labels: "routing labels must reference non-empty backend names"]

                true ->
                  []
              end
            end)
        end
      end)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_many(:runtimes, Runtime, on_replace: :delete)
    embeds_one(:backends, Backends, on_replace: :update, defaults_to_struct: true)
    embeds_one(:routing, Routing, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> normalize_backends_config()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        default_turn_sandbox_policy(workspace || settings.workspace.root)
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        default_runtime_turn_sandbox_policy(workspace || settings.workspace.root)
    end
  end

  @spec resolve_runtime_for_issue(%{labels: [String.t()]}, [Runtime.t()]) :: Runtime.t()
  def resolve_runtime_for_issue(issue, runtimes) when is_list(runtimes) do
    issue_labels =
      (Map.get(issue, :labels) || [])
      |> MapSet.new(&String.downcase/1)

    labeled =
      Enum.find(runtimes, fn rt ->
        rt.labels != [] and
          Enum.any?(rt.labels, fn l -> MapSet.member?(issue_labels, String.downcase(l)) end)
      end)

    labeled || Enum.find(runtimes, fn rt -> rt.labels == [] end) || List.first(runtimes)
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp normalize_backends_config(config) when is_map(config) do
    normalized_backends =
      case Map.get(config, "backends") do
        %{} = backends ->
          normalize_backends_section(backends)

        _ ->
          legacy_backends_from_codex(Map.get(config, "codex"))
      end

    Map.put(config, "backends", normalized_backends)
  end

  defp normalize_backends_section(%{"entries" => entries} = backends) when is_list(entries) do
    normalized_entries =
      Enum.map(entries, fn
        %{} = entry -> entry
        entry -> %{"name" => to_string(entry), "command" => entry}
      end)

    %{
      "default" => normalize_optional_string(Map.get(backends, "default")) || "codex",
      "entries" => normalized_entries
    }
  end

  defp normalize_backends_section(backends) do
    entries =
      backends
      |> Enum.reject(fn {name, _attrs} -> to_string(name) == "default" end)
      |> Enum.map(fn {name, attrs} -> normalize_backend_entry_map(name, attrs) end)

    %{
      "default" => normalize_optional_string(Map.get(backends, "default")) || "codex",
      "entries" => entries
    }
  end

  defp normalize_backend_entry_map(name, %{} = attrs) do
    Map.put(attrs, "name", to_string(name))
  end

  defp normalize_backend_entry_map(name, attrs) do
    %{"name" => to_string(name), "command" => attrs}
  end

  defp legacy_backends_from_codex(%{} = codex) do
    codex_overrides = drop_nil_values(codex)

    codex_entry =
      default_codex_backend_entry()
      |> Map.merge(codex_overrides)
      |> Map.put("name", "codex")
      |> Map.put_new("adapter", "codex")

    %{"default" => "codex", "entries" => [codex_entry]}
  end

  defp legacy_backends_from_codex(_other) do
    codex_entry =
      default_codex_backend_entry()
      |> Map.put("name", "codex")
      |> Map.put_new("adapter", "codex")

    %{"default" => "codex", "entries" => [codex_entry]}
  end

  defp default_codex_backend_entry do
    %{
      "command" => "codex app-server",
      "approval_policy" => %{
        "reject" => %{
          "sandbox_approval" => true,
          "rules" => true,
          "mcp_elicitations" => true
        }
      },
      "thread_sandbox" => "workspace-write",
      "turn_timeout_ms" => 3_600_000,
      "read_timeout_ms" => 5_000,
      "stall_timeout_ms" => 300_000
    }
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:runtimes, with: &Runtime.changeset/2)
    |> cast_embed(:backends, with: &Backends.changeset/2)
    |> cast_embed(:routing, with: &Routing.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> validate_backend_references()
  end

  defp finalize_settings(settings) do
    api_key_fallback =
      case settings.tracker.kind do
        "plane" -> System.get_env("PLANE_API_KEY")
        _ -> System.get_env("LINEAR_API_KEY")
      end

    endpoint =
      case settings.tracker.kind do
        "plane" ->
          resolve_secret_setting(settings.tracker.endpoint, System.get_env("PLANE_BASE_URL")) ||
            "http://localhost"

        _ ->
          settings.tracker.endpoint
      end

    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, api_key_fallback),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE")),
        endpoint: endpoint
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    agent = %{
      settings.agent
      | backend: normalize_agent_backend(settings.agent.backend)
    }

    backends = normalize_backend_entries(settings.backends)

    routing = %{
      settings.routing
      | labels: normalize_routing_labels(settings.routing.labels),
        fallback: normalize_optional_string(settings.routing.fallback)
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    runtimes = finalize_runtimes(settings.runtimes, codex)

    default_backend_entry =
      Enum.find(backends.entries, fn backend -> backend.name == backends.default end)

    codex_final = codex_alias_from_backend(codex, default_backend_entry)

    %{settings | tracker: tracker, workspace: workspace, agent: agent, codex: codex_final, runtimes: runtimes, backends: backends, routing: routing}
  end

  defp finalize_runtimes([], codex) do
    [
      %Runtime{
        name: "default",
        command: codex.command,
        labels: [],
        max_turns: nil,
        approval_policy: codex.approval_policy,
        thread_sandbox: codex.thread_sandbox,
        turn_sandbox_policy: codex.turn_sandbox_policy,
        turn_timeout_ms: codex.turn_timeout_ms,
        read_timeout_ms: codex.read_timeout_ms,
        stall_timeout_ms: codex.stall_timeout_ms
      }
    ]
  end

  defp finalize_runtimes(runtimes, _codex) when is_list(runtimes), do: runtimes

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)
  defp normalize_optional_map(value), do: value

  defp normalize_optional_policy(nil), do: nil
  defp normalize_optional_policy(value) when is_map(value), do: normalize_keys(value)
  defp normalize_optional_policy(value), do: value

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(value), do: value |> to_string() |> normalize_optional_string()

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp normalize_backend_entries(%Backends{} = backends) do
    entries =
      Enum.map(backends.entries, fn entry ->
        %{
          entry
          | name: normalize_optional_string(entry.name),
            adapter: normalize_optional_string(entry.adapter) || normalize_optional_string(entry.name),
            command: normalize_optional_string(entry.command),
            approval_policy: normalize_optional_policy(entry.approval_policy),
            thread_sandbox: normalize_optional_string(entry.thread_sandbox),
            turn_sandbox_policy: normalize_optional_map(entry.turn_sandbox_policy),
            permission_mode: normalize_optional_string(entry.permission_mode),
            model: normalize_optional_string(entry.model)
        }
      end)

    %{backends | default: normalize_optional_string(backends.default) || "codex", entries: entries}
  end

  defp normalize_backend_entries(backends), do: backends

  defp normalize_routing_labels(nil), do: %{}

  defp normalize_routing_labels(labels) when is_map(labels) do
    labels
    |> normalize_keys()
    |> Enum.reduce(%{}, fn {label, backend}, acc ->
      case normalize_optional_string(backend) do
        nil -> acc
        normalized_backend -> Map.put(acc, to_string(label), normalized_backend)
      end
    end)
  end

  defp normalize_routing_labels(_labels), do: %{}

  defp codex_alias_from_backend(codex, nil), do: codex

  defp codex_alias_from_backend(codex, backend) do
    %{
      codex
      | command: backend.command || codex.command,
        approval_policy: backend.approval_policy || codex.approval_policy,
        thread_sandbox: backend.thread_sandbox || codex.thread_sandbox,
        turn_sandbox_policy: backend.turn_sandbox_policy || codex.turn_sandbox_policy,
        turn_timeout_ms: backend.turn_timeout_ms || codex.turn_timeout_ms,
        read_timeout_ms: backend.read_timeout_ms || codex.read_timeout_ms,
        stall_timeout_ms: backend.stall_timeout_ms || codex.stall_timeout_ms
    }
  end

  defp validate_backend_references(changeset) do
    backend_names = backend_names(changeset)

    changeset
    |> validate_default_backend_reference(backend_names)
    |> validate_routing_backend_references(backend_names)
  end

  defp backend_names(changeset) do
    case get_field(changeset, :backends) do
      %Backends{entries: entries} ->
        entries
        |> Enum.map(fn entry -> normalize_optional_string(entry.name) end)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp validate_default_backend_reference(changeset, backend_names) do
    case get_field(changeset, :backends) do
      %Backends{default: default_backend} ->
        default_backend = normalize_optional_string(default_backend)

        cond do
          is_nil(default_backend) ->
            add_error(changeset, :backends, "backends.default must be a non-empty backend name")

          MapSet.member?(backend_names, default_backend) ->
            changeset

          true ->
            add_error(
              changeset,
              :backends,
              "backends.default references unknown backend #{inspect(default_backend)}"
            )
        end

      _ ->
        changeset
    end
  end

  defp validate_routing_backend_references(changeset, backend_names) do
    case get_field(changeset, :routing) do
      %Routing{} = routing ->
        changeset
        |> validate_routing_fallback_reference(routing.fallback, backend_names)
        |> validate_routing_label_references(routing.labels, backend_names)

      _ ->
        changeset
    end
  end

  defp validate_routing_fallback_reference(changeset, fallback, backend_names) do
    case normalize_optional_string(fallback) do
      nil ->
        changeset

      backend_name ->
        if MapSet.member?(backend_names, backend_name) do
          changeset
        else
          add_error(
            changeset,
            :routing,
            "routing.fallback references unknown backend #{inspect(backend_name)}"
          )
        end
    end
  end

  defp validate_routing_label_references(changeset, labels, backend_names) when is_map(labels) do
    Enum.reduce(labels, changeset, fn {label, backend_name}, acc ->
      case normalize_optional_string(backend_name) do
        nil ->
          acc

        normalized_backend ->
          if MapSet.member?(backend_names, normalized_backend) do
            acc
          else
            add_error(
              acc,
              :routing,
              "routing.labels.#{label} references unknown backend #{inspect(normalized_backend)}"
            )
          end
      end
    end)
  end

  defp validate_routing_label_references(changeset, _labels, _backend_names), do: changeset

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        Path.expand(default)

      "" ->
        Path.expand(default)

      path ->
        Path.expand(path)
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp normalize_agent_backend(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "codex"
      trimmed -> trimmed
    end
  end

  defp normalize_agent_backend(_value), do: "codex"

  defp default_turn_sandbox_policy(workspace) do
    writable_root =
      if is_binary(workspace) and workspace != "" do
        Path.expand(workspace)
      else
        Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
      end

    %{
      "type" => "workspaceWrite",
      "writableRoots" => [writable_root],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root) when is_binary(workspace_root) do
    with {:ok, canonical_workspace_root} <- PathSafety.canonicalize(workspace_root) do
      {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.flat_map(errors, fn
      value when is_binary(value) ->
        [prefix <> " " <> value]

      value when is_map(value) or is_list(value) ->
        flatten_errors(value, prefix)

      value ->
        [prefix <> " " <> to_string(value)]
    end)
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
