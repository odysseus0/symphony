# Quality Score

## Quality Gates

All changes must pass `make all`:

| Gate | Command | Threshold |
|------|---------|-----------|
| Format | `mix format --check-formatted` | Zero violations |
| Lint | `mix credo --strict` | Zero issues |
| Specs | `mix specs.check` | All public `def` have `@spec` |
| Tests | `mix test --cover` | 100% on non-ignored modules |
| Types | `mix dialyzer` | Zero warnings |

## Test Coverage

Coverage threshold: 100% (on measured modules). Integration-heavy modules excluded via `ignore_modules` in `mix.exs`.

## Code Standards

- Public functions require `@spec`
- `@impl` callbacks exempt from local `@spec`
- Immutable data patterns (Elixir default)
- Narrow scope per change — no unrelated refactors
