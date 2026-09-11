defmodule BC.Ingest.Worker do
  @moduledoc """
  Process a single spec chunk via the ingest model.

  Extracts board fields (soc, ram_start, uart, etc.) with evidence strings.
  Each field must have a verbatim evidence substring from the chunk.
  """

  require Logger

  @spec process_chunk(String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def process_chunk(chunk_text) do
    model_client = Application.get_env(:bc, :model_client, BC.Model.OpenAI)

    # Get config with fallback
    config = Application.get_env(:bc, :config)

    ingest_model =
      if config do
        config.ingest_model
      else
        # Fallback for tests
        "gpt-4"
      end

    prompt = extraction_prompt(chunk_text)

    messages = [
      %{
        role: :user,
        content: prompt,
        tool_calls: nil,
        tool_call_id: nil
      }
    ]

    case model_client.chat(
           messages,
           [model: ingest_model, temperature: 0.0, tools: []],
           fn _chunk -> :ok end
         ) do
      {:ok, result} ->
        parse_extraction(result.text, chunk_text)

      {:error, error} ->
        Logger.error("Ingest extraction failed: #{inspect(error)}")
        {:error, inspect(error)}
    end
  end

  defp extraction_prompt(chunk_text) do
    """
    Extract board specification fields from the following text. Return a JSON object with fields found.

    For each field you extract, include an "evidence_<fieldname>" string with the verbatim text from the document that supports the field value. Only include evidence for fields you actually extract.

    Supported fields (all optional, omit if not found in text):
    - soc: System-on-Chip name (e.g., "i.MX6UL", "STM32H7")
    - goarch: Go architecture (arm, arm64, riscv64)
    - goarm: Go ARM version (5, 6, 7)
    - ram_start: RAM start address (e.g., "0x80000000")
    - ram_size: RAM size (e.g., "512MB", "0x20000000")
    - uart: UART name (e.g., "UART2", "USART1")
    - peripherals: List of peripheral names (e.g., ["gpio", "usb"])
    - pinmux: List of {signal, pad, fn} objects (only if the document names them)
    - tamago_soc: TamaGo SoC name
    - tamago_board: TamaGo board name
    - notes: Any relevant notes

    CRITICAL RULES:
    1. Never infer or guess values based on SoC knowledge. Only extract what is explicitly stated in the text.
    2. Do not extract register addresses or memory sizes that are not explicitly mentioned.
    3. For pad names and pinmux, only include if explicitly named in the document.
    4. Only extract peripherals if they are explicitly named.
    5. Omit any field not found in the text.
    6. Evidence must be a verbatim substring from the chunk.

    Text to analyze:
    ---
    #{chunk_text}
    ---

    Return ONLY a JSON object (no explanation, no markdown, no code fence). Example format:
    {"soc": "i.MX6UL", "evidence_soc": "i.MX6UL", "ram_start": "0x80000000", "evidence_ram_start": "0x80000000"}
    """
  end

  defp parse_extraction(response_text, chunk_text) do
    response_text = String.trim(response_text)

    # Try to extract JSON from the response
    json_text =
      if String.starts_with?(response_text, "{") do
        response_text
      else
        # Try to find JSON in the response
        case Regex.run(~r/\{.*\}/s, response_text) do
          [json] -> json
          nil -> response_text
        end
      end

    case Jason.decode(json_text) do
      {:ok, extracted} ->
        # Validate evidence strings and build result
        validated = validate_evidence(extracted, chunk_text)
        {:ok, validated}

      {:error, _} ->
        Logger.debug("Failed to parse extraction JSON: #{json_text}")
        {:ok, %{}}
    end
  end

  defp validate_evidence(extracted, chunk_text) do
    # Filter out any evidence that is not verbatim in the chunk
    extracted
    |> Enum.filter(fn
      {key, _value} when is_binary(key) ->
        if String.starts_with?(key, "evidence_") do
          # This is an evidence field
          false
        else
          true
        end

      _ ->
        false
    end)
    |> Enum.into(%{})
    |> Enum.reduce(%{}, fn {field_name, field_value}, acc ->
      evidence_key = "evidence_#{field_name}"

      case extracted[evidence_key] do
        evidence when is_binary(evidence) ->
          # Check if evidence is verbatim in chunk
          if String.contains?(chunk_text, evidence) do
            Map.put(acc, field_name, %{value: field_value, evidence: evidence})
          else
            # Fabricated evidence, drop the field
            Logger.debug("Evidence not found for #{field_name}: #{evidence}")
            acc
          end

        nil ->
          # No evidence provided, drop the field
          Logger.debug("No evidence for field: #{field_name}")
          acc

        _ ->
          # Invalid evidence
          acc
      end
    end)
  end
end
