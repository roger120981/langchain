defmodule Langchain.MessageDelta do
  @moduledoc """
  Models a "delta" message from a chat LLM. A delta is a small chunk of a
  complete message. A series of deltas can be used to construct a complete
  message.

  ## Roles

  - `:unknown` - The role data is missing for the delta.
  - `:assistant` - Responses coming back from the LLM.
  - `:function_call` - A message from the LLM expressing the intent to execute a
    function that was previously declared available to it.

    The `arguments` will eventually be parsed from JSON. However, as deltas are
    streamed, the arguments come in as text. Once it is fully received it can be
    parsed as JSON, but it cannot be used before it is complete.

  """
  use Ecto.Schema
  import Ecto.Changeset
  require Logger
  alias __MODULE__
  alias Langchain.LangchainError
  alias Langchain.Message
  alias Langchain.Utils

  @primary_key false
  embedded_schema do
    field :content, :string
    field :index, :integer
    field :function_name, :string

    field :role, Ecto.Enum, values: [:unknown, :assistant, :function_call], default: :unknown

    field :arguments, :string
    # Marks if the delta completes the message.
    field :complete, :boolean, default: false
  end

  @type t :: %MessageDelta{}

  @create_fields [:role, :content, :function_name, :arguments, :index, :complete]
  @required_fields []

  @doc """
  Create a new MessageDelta that represents a message chunk.
  """
  @spec new(attrs :: map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs \\ %{}) do
    %MessageDelta{}
    |> cast(attrs, @create_fields)
    |> assign_arguments(attrs)
    |> validate_required(@required_fields)
    |> apply_action(:insert)
  end

  @doc """
  Build a new MessageDelta that represents a message chunk and return it or
  raise an error if invalid.
  """
  @spec new!(attrs :: map()) :: t() | no_return()
  def new!(attrs \\ %{}) do
    case new(attrs) do
      {:ok, message} ->
        message

      {:error, changeset} ->
        raise LangchainError, changeset
    end
  end

  @doc """
  Merge two MessageDelta structs. The first MessageDelta is the `primary` one
  that smaller deltas are merged into.
  """
  def merge_delta(%MessageDelta{role: :assistant} = primary, %MessageDelta{} = delta_part) do
    primary
    |> append_content(delta_part)
    |> update_index(delta_part)
    |> update_complete(delta_part)
  end

  def merge_delta(%MessageDelta{role: :function_call} = primary, %MessageDelta{} = delta_part) do
    primary
    |> append_arguments(delta_part)
    |> update_index(delta_part)
    |> update_complete(delta_part)
  end

  defp append_content(%MessageDelta{role: :assistant} = primary, %MessageDelta{
         content: new_content
       })
       when is_binary(new_content) do
    %MessageDelta{primary | content: (primary.content || "") <> new_content}
  end

  defp append_content(%MessageDelta{} = primary, %MessageDelta{} = _delta_part) do
    # no content to merge
    primary
  end

  defp update_index(%MessageDelta{} = primary, %MessageDelta{index: new_index})
       when is_number(new_index) do
    %MessageDelta{primary | index: new_index}
  end

  defp update_index(%MessageDelta{} = primary, %MessageDelta{} = _delta_par) do
    # no index update
    primary
  end

  defp update_complete(%MessageDelta{complete: false} = primary, %MessageDelta{complete: true}) do
    %MessageDelta{primary | complete: true}
  end

  defp update_complete(%MessageDelta{} = primary, %MessageDelta{} = _delta_part) do
    # complete flag not updated
    primary
  end

  defp append_arguments(%MessageDelta{role: :function_call} = primary, %MessageDelta{
         arguments: new_arguments
       })
       when is_binary(new_arguments) do
    %MessageDelta{primary | arguments: (primary.arguments || "") <> new_arguments}
  end

  defp append_arguments(%MessageDelta{} = primary, %MessageDelta{} = _delta_part) do
    # no arguments to merge
    primary
  end

  # The arguments get streamed as a string. A delta of " " a single empty space
  # is expected. The "cast" process of the changeset turns this into `nil`
  # causing us to lose data.
  #
  # We want to take whatever we are given here.
  defp assign_arguments(changeset, attrs) do
    # get both possible versions of the arguments.
    args = Map.get(attrs, :arguments) || Map.get(attrs, "arguments")
    # if we got a string, use it as-is without casting
    if is_binary(args) do
      put_change(changeset, :arguments, args)
    else
      changeset
    end
  end

  @doc """
  Convert the MessageDelta to a Message. Some messages must be complete before
  they can be transformed to a message. For instance, an incomplete
  `:function_call` cannot be used. However, an incomplete `:assistant` message
  with content can be used before fully complete.
  """
  @spec to_message(t()) :: {:ok, Message.t()} | {:error, String.t()}
  def to_message(%MessageDelta{} = delta) do
    case Message.new(Map.from_struct(delta)) do
      {:ok, message} ->
        {:ok, message}

      {:error, changeset} ->
        {:error, Utils.changeset_error_to_string(changeset)}
    end
  end
end