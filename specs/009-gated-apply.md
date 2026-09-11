# 009 — Human-gated apply (`ws.apply`)

Build-order step 3 (second half). Depends on 008.

Read [`000-overview.md`](000-overview.md) first. Enforces **I4**, **I8**.

## Goal

"Apply is a keybind, not a tool the model can fire on its own." The single write path into
the working tree, reachable only with a permit that a human keypress mints.

## Scope

In: `BC.Permit`, `BC.Patch.Apply`, the `BC.Proposal` status transitions and the
`:apply_result` event.

Out: the keybind itself (011), the patch parsing (008).

## Design

### `BC.Permit`

```elixir
@opaque t :: %BC.Permit{proposal_id: String.t(), session_id: String.t(),
                           nonce: binary(), issued_at: integer()}
@spec mint(String.t(), String.t()) :: t()
@spec consume(t()) :: :ok | {:error, :expired | :spent | :unknown}
```

- Minted **only** by `BC.TUI` on an explicit accept keypress, and only for the
  currently displayed pending proposal. There is exactly one call site in `lib/`, and a
  test asserts that by grepping.
- Single use: `consume/1` records the nonce in an ETS set; a second consume →
  `{:error, :spent}`.
- Expires after 5 minutes (`:expired`). An operator who walked away re-presses the key
  rather than applying a patch they have stopped looking at.
- `mint/2` takes the proposal id **and the patch's sha256**, stored in the struct; apply
  re-hashes the proposal's patch and refuses on mismatch (`:stale`). A superseded
  proposal therefore cannot be applied by a permit minted for the old one.

### `BC.Patch.Apply`

Behaviour + implementation (overview §7 seam `:patch_applier`).

```elixir
@callback apply_patch(Proposal.t(), Permit.t()) ::
            {:ok, %{output: String.t(), files: [String.t()]}} | {:error, err()}
```

Sequence, aborting on the first failure and leaving the tree untouched:

1. `Permit.consume/1`. No permit, spent, expired, stale, or wrong proposal →
   `{:error, %{code: :no_permit}}`. **This check is first, before any filesystem access.**
2. Re-run `BC.Proposal.Patch.parse/1` and the sandbox check on every target path (do
   not trust what was validated at propose time — the tree may have changed).
3. Write the patch to a temp file under `System.tmp_dir!()`.
4. Port: `git -C <tree_root> apply --check --whitespace=nowarn <tmpfile>` (argv,
   `:spawn_executable`, no shell, 30 s timeout). Non-zero → `{:error, %{code:
   :patch_conflict, message: <git's stderr>}}`, tree untouched.
5. Port: `git -C <tree_root> apply --whitespace=nowarn <tmpfile>`. Non-zero →
   `:patch_failed` (should be unreachable after `--check`; report loudly if reached).
6. Delete the temp file. Return the touched file list from the parse.
7. Caller (`BC.Session.note_applied/3`) sets the proposal `:applied`, broadcasts
   `:apply_result`, and appends to the transcript: `"The operator applied proposal <id>.
   Files: a.go, b.go. Use ws.diff to see the tree, tamago.build to check it."` — the
   model must learn the outcome from the system, not be told by the TUI's rendering.
8. On rejection (the other keybind), no filesystem access at all: proposal `:rejected`,
   broadcast, and a transcript note `"The operator rejected proposal <id>. Reason: <text
   or none given>."` so the next turn does not re-propose the same thing.

`git` absence is detected at startup (`System.find_executable("git")`); if missing, the
TUI shows apply as unavailable rather than failing at the keypress.

**No commit, no checkout, no branch, no stash, no reset.** `git apply` is the only git
subcommand this module runs; `ws.diff`'s `git diff` (007) is the only other one in the
codebase. The operator owns their VCS.

## Acceptance criteria

1. `apply_patch/2` with a permit minted for a different proposal id → `:no_permit`, and
   the working tree is byte-identical afterwards. **(I4)**
2. Same permit twice → second is `:spent`, tree unchanged after the second.
3. A permit older than 5 minutes → `:expired` (inject the clock; do not sleep).
4. A permit minted for proposal P, then P superseded by P2 (008) → applying P is
   `:stale`.
5. A patch that does not apply cleanly → `:patch_conflict` with git's message, and the
   tree is **byte-identical** to before (assert a recursive hash of the fixture tree).
6. A clean patch applies, returns the touched files, and the fixture tree's content
   matches expectation.
7. `:apply_result` is broadcast with `ok: true/false` in both cases.
8. After apply, the session transcript contains the applied-note naming the proposal and
   files; after reject, the rejected-note. **(so the model cannot claim it applied
   something, and cannot re-propose blindly)**
9. Grep test: `BC.Permit.mint/2` has exactly one call site outside tests, in
   `BC.TUI`. **(I4 — the permit lives with the human.)**
10. Grep test: no `git` subcommand other than `apply` and `diff` appears in `lib/`, and no
    port anywhere is spawned through a shell. **(I8)**
11. The model's tool list never contains an apply/write tool (re-asserted here against
    `BC.Tools.schemas/1`).

## Test plan

`test/bc/patch/apply_test.exs` against a real fixture git repo created per test in a
tmp dir (`git init`, one commit), skipped with a clear message if `git` is unavailable.
Hash the whole tree before/after for the "unchanged" assertions.
`test/bc/permit_test.exs` for mint/consume/expiry/staleness with an injected clock.

## Constraints

- The model has no path to this module. If a future tool needs to call it, that is a
  `PRODUCT.md` change.
- Never apply and build in one action. Build is a separate operator decision (010, 011).
