defimpl Inspect, for: Runic.Identity do
  import Inspect.Algebra

  def inspect(identity, _opts) do
    concat(["#Runic.Identity<", Runic.Identity.short_string(identity), ">"])
  end
end
