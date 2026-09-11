defmodule BC.Tools do
  @moduledoc """
  Closed-world tool registry: schemas and dispatch.

  Enforces invariants I2 (sandbox confinement) and I3 (no network/shell).
  """

  alias BC.Config

  @type ctx :: %{
          session_id: String.t(),
          read_log: pid() | :ets.tid(),
          proposal_store: :ets.tid() | nil,
          kb_root: Path.t() | nil,
          tree_root: Path.t() | nil
        }

  @spec schemas(Config.t()) :: [map()]
  def schemas(config) do
    base = [
      kb_search_schema(),
      kb_read_schema(),
      propose_patch_schema()
    ]

    tree_tools =
      if config.tree_root do
        [
          ws_read_schema(),
          ws_list_schema(),
          ws_diff_schema(),
          tamago_build_schema()
        ]
      else
        []
      end

    base ++ tree_tools
  end

  @spec call(String.t(), String.t(), ctx()) ::
          {:ok, String.t()} | {:error, %{code: atom(), message: String.t()}}
  def call(tool_name, json_args, ctx) do
    case Jason.decode(json_args) do
      {:error, _} ->
        {:error, %{code: :invalid_args, message: "arguments were not valid JSON: #{json_args}"}}

      {:ok, args} ->
        case call_impl(tool_name, args, ctx) do
          result when is_tuple(result) and elem(result, 0) in [:ok, :error] ->
            result

          other ->
            {:error, %{code: :internal_error, message: "unexpected result: #{inspect(other)}"}}
        end
    end
  rescue
    e ->
      {:error, %{code: :tool_crashed, message: Exception.message(e)}}
  end

  # --- Schemas ---

  defp kb_search_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => "kb.search",
        "description" =>
          "Search the knowledge base for boards matching criteria. At least one of soc, text, or peripherals is required.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "soc" => %{"type" => "string", "description" => "Target SoC (e.g., imx6ul, stm32h7)"},
            "uart" => %{"type" => "string", "description" => "UART instance (e.g., UART2)"},
            "peripherals" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "List of peripherals to search for (e.g., gpio, usb, usdhc)"
            },
            "text" => %{"type" => "string", "description" => "Free-text search in board facts"},
            "limit" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 20,
              "description" => "Max results (default 5)"
            }
          },
          "required" => []
        }
      }
    }
  end

  defp kb_read_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => "kb.read",
        "description" =>
          "Read a file from the knowledge base (board.toml, schematic reference, etc.)",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "KB-relative path (e.g., boards/mk2/board.toml)"
            },
            "max_bytes" => %{
              "type" => "integer",
              "description" => "Max file size to read (default 256 KiB)"
            }
          },
          "required" => ["path"]
        }
      }
    }
  end

  defp ws_read_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => "ws.read",
        "description" => "Read a file from the working tree",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Tree-relative path"},
            "max_bytes" => %{
              "type" => "integer",
              "description" => "Max file size to read (default 256 KiB)"
            }
          },
          "required" => ["path"]
        }
      }
    }
  end

  defp ws_list_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => "ws.list",
        "description" => "List files and directories in the working tree",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Tree-relative path (default .)"},
            "depth" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 3,
              "description" => "Recursion depth (default 1)"
            }
          },
          "required" => []
        }
      }
    }
  end

  defp ws_diff_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => "ws.diff",
        "description" => "Show uncommitted changes in the working tree (git diff)",
        "parameters" => %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        }
      }
    }
  end

  defp tamago_build_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => "tamago.build",
        "description" => "Build the TamaGo firmware",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "package" => %{
              "type" => "string",
              "description" => "Go package path to build (default ./...)"
            }
          },
          "required" => []
        }
      }
    }
  end

  defp propose_patch_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => "propose_patch",
        "description" =>
          "Propose a BSP patch for the new board. The human reviews and applies it; you cannot apply it yourself.",
        "parameters" => %{
          "type" => "object",
          "required" => ["nearest_board_id", "summary", "patch", "citations"],
          "properties" => %{
            "nearest_board_id" => %{
              "type" => "string",
              "description" => "id of the KB board this port is derived from"
            },
            "summary" => %{
              "type" => "string",
              "description" => "what changes and why, 1-5 sentences"
            },
            "deltas" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "required" => ["field", "from", "to"],
                "properties" => %{
                  "field" => %{"type" => "string"},
                  "from" => %{"type" => "string"},
                  "to" => %{"type" => "string"}
                }
              }
            },
            "patch" => %{
              "type" => "string",
              "description" =>
                "unified diff against the working tree, paths relative to the tree root"
            },
            "citations" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "required" => ["path", "claim"],
                "properties" => %{
                  "path" => %{
                    "type" => "string",
                    "description" => "KB path you read with kb.read"
                  },
                  "claim" => %{
                    "type" => "string",
                    "description" => "the specific address, pin, size or name this file supports"
                  }
                }
              }
            }
          }
        }
      }
    }
  end

  # --- Dispatch ---

  defp call_impl("kb.search", args, ctx) do
    BC.Tools.KB.search(args, ctx)
  end

  defp call_impl("kb.read", args, ctx) do
    BC.Tools.KB.read(args, ctx)
  end

  defp call_impl("ws.read", args, ctx) do
    BC.Tools.WS.read(args, ctx)
  end

  defp call_impl("ws.list", args, ctx) do
    BC.Tools.WS.list(args, ctx)
  end

  defp call_impl("ws.diff", args, ctx) do
    BC.Tools.WS.diff(args, ctx)
  end

  defp call_impl("tamago.build", args, ctx) do
    BC.Tools.Build.build(args, ctx)
  end

  defp call_impl("propose_patch", args, ctx) do
    BC.Tools.Propose.propose(args, ctx)
  end

  defp call_impl(unknown_tool, _args, _ctx) do
    available =
      "kb.search, kb.read, ws.read, ws.list, ws.diff, tamago.build, propose_patch"

    message =
      "no such tool. bc has no network and no shell. available: #{available}"

    {:error, %{code: :unknown_tool, message: message}}
  end
end
