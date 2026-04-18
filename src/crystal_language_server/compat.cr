module CrystalLanguageServer
  # Crystal 1.19 renamed `Time.monotonic` to `Time.instant` (and changed
  # the return type from `Time::Span` to the richer `Time::Instant`),
  # deprecating the old API. To stay clean on 1.19+ without breaking
  # 1.17/1.18 CI, resolve the right type + call at compile time.
  {% if compare_versions(Crystal::VERSION, "1.19.0") >= 0 %}
    alias MonoInstant = ::Time::Instant
  {% else %}
    alias MonoInstant = ::Time::Span
  {% end %}

  macro monotonic_now
    {% if compare_versions(Crystal::VERSION, "1.19.0") >= 0 %}
      ::Time.instant
    {% else %}
      ::Time.monotonic
    {% end %}
  end
end
