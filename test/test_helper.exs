Application.put_env(:hatch, :model_client, Hatch.Model.Fake)
Application.put_env(:hatch, :halt, fn code -> throw({:halted, code}) end)

ExUnit.start()
