defmodule Runic.TestSupport.NativeReadSpy do
  @moduledoc false
  def load_fact(hash, observer) do
    send(observer, {:native_store_read, hash})
    {:ok, 7}
  end
end
