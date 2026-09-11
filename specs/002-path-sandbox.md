# 002 — Path sandbox

Build-order step 1. Security-critical, pure, no processes.

Read [`000-overview.md`](000-overview.md) first. Enforces **I2**.

## Goal

One module that every tool must go through to turn a model-supplied path into a real
path, or refuse. `PRODUCT.md`: "Tools that can leave that path do not exist." This is
the module that makes that true.

## Scope

In: `Hatch.Sandbox` — resolution, confinement, file reads with size/type guards, listing.

Out: the tools themselves (007), the KB semantics (003), anything that writes (009).

## Design

```elixir
@type root :: :kb | :tree
@type err :: %{code: atom(), message: String.t()}

@spec resolve(root(), String.t()) :: {:ok, Path.t()} | {:error, err()}
@spec read(root(), String.t(), keyword()) :: {:ok, String.t()} | {:error, err()}
@spec list(root(), String.t(), keyword()) :: {:ok, [entry()]} | {:error, err()}
@spec relative(root(), Path.t()) :: {:ok, String.t()} | {:error, err()}
@spec under?(root(), Path.t()) :: boolean()
```

Roots come from `Hatch.Config.get/0`: `:kb` → `kb_root`, `:tree` → `tree_root`.
`:tree` when `tree_root` is `nil` → `{:error, %{code: :no_tree}}`.

### `resolve/2`

Input is a **root-relative** path as the model wrote it. Steps, in order:

1. Reject absolute inputs (`Path.type/1 != :relative`) → `:outside_sandbox`.
2. Reject any path containing a NUL byte or a `..` segment after `Path.split/1`
   → `:outside_sandbox`. (Rejecting `..` syntactically as well as after expansion is
   deliberate: it makes the error legible to the model.)
3. `full = Path.expand(input, root)`.
4. Resolve symlinks: walk the existing prefix of `full` with `:file.read_link_all/1` and
   fully expand. Equivalent and acceptable: `:file.read_file_info/2` plus
   `Path.expand` of each link target, iterated with a depth cap of 16
   (`:symlink_loop` on exceeding it).
5. The resolved real path must be the root itself or start with `root <> "/"` —
   compare on split segments, not string prefix, so `/kb-evil` is not accepted for root
   `/kb`. Else `:outside_sandbox`.
6. The root itself is also symlink-resolved once, at first use, and memoised in
   `:persistent_term` — otherwise a symlinked root fails its own check.

`resolve/2` does **not** require the path to exist; `read/3` and `list/3` do.

### `read/3`

- `resolve/2`, then `File.stat` → `:not_found` when missing, `:not_a_file` for dirs.
- `:max_bytes` option, default `256 * 1024`. Larger → `{:error, %{code: :too_large,
  message: "file is N bytes; max 262144. Read a smaller file or ask for a specific section."}}`.
- Binary sniff: if the first 8 KiB contain a NUL byte or the content is not valid UTF-8,
  → `{:error, %{code: :binary_file, message: "<path> is not text. Schematics are ingested
  offline into board.toml / nets.json; they are not read live."}}`. This is the
  `PRODUCT.md` rule "It does not OCR a blob every turn", enforced rather than requested.
- Success returns the file as a UTF-8 string.

### `list/3`

- `resolve/2` on a directory. Options: `:depth` (default 1, max 3), `:limit` (default
  500 entries, then truncate and set `truncated: true` in the return).
- Returns `[%{path: String.t(), type: :file | :dir, size: non_neg_integer()}]` with
  **root-relative** paths, sorted, directories first.
- Symlinks that resolve outside the root are omitted silently (they are not the caller's
  business), symlinks inside are listed as their target type.
- Skips `.git/` and any entry starting with `.` at any depth. Rationale: the model has no
  use for git internals and they blow the entry budget.

### `relative/2`

Inverse of `resolve/2`, for turning an internal absolute path back into something quotable
in a citation. Errors with `:outside_sandbox` rather than returning a `../..` path.

## Acceptance criteria

For root `kb` containing `boards/x/board.toml`:

1. `resolve(:kb, "boards/x/board.toml")` → `{:ok, abs}`.
2. Each of `"../etc/passwd"`, `"boards/../../etc/passwd"`, `"/etc/passwd"`,
   `"boards/x/../../../etc/passwd"` → `{:error, %{code: :outside_sandbox}}`. **(I2)**
3. A symlink `kb/boards/evil -> /etc` resolves to `:outside_sandbox` on
   `read(:kb, "boards/evil/passwd")`; a symlink inside the KB resolves normally.
4. A symlink loop returns `:symlink_loop`, does not hang.
5. `read` of a 1 MiB file → `:too_large`; of a PDF (or any file with a NUL in the first
   8 KiB) → `:binary_file` with a message that says schematics are ingested offline.
6. `read(:tree, _)` with `tree_root: nil` → `:no_tree`.
7. `list(:kb, ".", depth: 2)` returns root-relative paths only, contains no `.git`
   entries, and truncates at the limit with `truncated: true`.
8. A root that is itself a symlink works for every case above.
9. No function in this module ever returns a path outside its root, including in error
   messages — error messages echo the **input** path, never the expanded one, so the
   module cannot leak the filesystem layout to the model.

## Test plan

`test/hatch/sandbox_test.exs`. Build fixture trees under `System.tmp_dir!()` per test
(`on_exit` cleanup), including symlinks created with `File.ln_s/2`. Property-style loop
over a table of hostile inputs. Skip symlink cases on platforms where `File.ln_s/2`
returns `{:error, :enotsup}` rather than failing the suite.

## Constraints

- Pure functions plus `File`/`:file` calls. No GenServer, no ETS beyond the memoised root.
- No `System.cmd`, no `Path.safe_relative/2`-only trust: resolve symlinks explicitly
  (`Path.safe_relative/2` does not know about links).
