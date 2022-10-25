defmodule Membrane.LiveFramerateConverter do
  @moduledoc """
    Drops or duplicates buffers producing a stable output framerate, starts
    when the first packet one is received.
  """

  use Membrane.Filter

  def_options framerate: [
                spec: {pos_integer(), pos_integer()},
                default: {30, 1},
                description: """
                Target framerate.
                """
              ]

  def_input_pad :input, caps: :any, demand_unit: :buffers, demand_mode: :auto
  def_output_pad :output, caps: :any, mode: :push

  @impl true
  def handle_init(%__MODULE__{} = opts) do
    {:ok, %{framerate: opts.framerate}}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    {{:ok, buffer: {:output, buffer}}, state}
  end

end
