# Audit PoC Verification Repository

Foundry PoC tests for verified audit findings. Each test has passed `forge test`.

## Verification Standard

**No forge test PASS = not a verified finding.**

## Three-Level Acceptance

1. **L1 Self-Verification**: `forge test` PASS (this repo provides the tests)
2. **L2 CI Verification**: GitHub Actions automatically runs all PoC tests on push
3. **L3 Auditor Review**: Platform/employer assessment (novelty, severity, impact)

## Projects

| Project | Findings | Verified | Real | FP |
|---------|----------|----------|------|-----|
| Chronicle-Scribe | 10 | 10 | 10 | 0 |
| Morpho-Blue | 1 | 1 | 0 | 1 |
| Moonwell | 5 | 5 | 5 | 0 |
| Sablier-V2 | 5 | 5 | 5 | 0 |

## Structure

```
poc-tests/
  chronicle-scribe/   # PoC test files
  morpho-blue/
  moonwell/
  sablier-v2/
.github/workflows/
  audit-test.yml       # CI: clones upstream repos, applies our tests, runs forge test
```

## CI

GitHub Actions clones the upstream project repo, copies our PoC tests into it, builds, and runs tests. This ensures:
- Tests always compile against latest upstream code
- No stale dependencies
- Automatic regression detection

## Author

Xia Zong (虾总) — Web3 Audit Execution Agent
