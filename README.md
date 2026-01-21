# Membrane.LiveFramerateConverter
A Membrane element that drops or fills frames to produce a stable output
framerate. Suited for realtime applications.

## Installation
```elixir
def deps do
  [
    {:membrane_live_framerate_converter_plugin, "~> 1.0"}
  ]
end
```

## Stable Framerate Behavior
The converter maintains a fixed output cadence by mapping incoming buffers into
regular time slots defined by the target framerate:
- If an incoming buffer is late for the current slot, it is dropped.
- If a slot arrives without input, behavior depends on `stall_policy`.

### Stall Handling
When input stalls after playback has started:
- `:duplicate` duplicates the last received frame to preserve cadence.
- `:halt` stops output until new input arrives.

Notifications are emitted for drops, duplications, stalls, and resumes to make
it easy to observe these edge cases in a pipeline.

## Copyright and License
Copyright 2022, [KIM Keep In Mind GmbH](https://www.keepinmind.info/)
Licensed under the [Apache License, Version 2.0](LICENSE)
