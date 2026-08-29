alias Runic.Identity

max_phash = 4_294_967_296

composite_phash2 = fn term ->
  high = :erlang.phash2(term, max_phash)
  low = :erlang.phash2({:phash2_64_v1, :secondary, term}, max_phash)
  high * max_phash + low
end

small = {%{answer: 42}, {:producer, :parent}}
large = {%{payload: :binary.copy(<<42>>, 64 * 1024)}, {:producer, :parent}}

Benchee.run(
  %{
    "phash2_64_v1" => composite_phash2,
    "runic_canonical_v1 + sha256" => &Identity.digest(:fact_content, &1)
  },
  inputs: %{"small Fact basis" => small, "64 KiB Fact basis" => large},
  time: 3,
  memory_time: 1,
  reduction_time: 1
)
