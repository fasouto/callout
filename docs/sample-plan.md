# Plan: add rate limiting

## Context

The API has **no limits** today, so a single client can exhaust the pool.
See [the incident report](https://example.com/incidents/42) for details.

## Steps

1. Add a `RateLimiter` middleware in `api/middleware.py`
   - token bucket, *per API key*
   - configurable via `RATE_LIMIT_RPS`
2. Return `429` with a `Retry-After` header
3. Tests:
   - [ ] unit tests for the bucket
   - [x] integration test hitting `/health`

```python
class RateLimiter:
    def allow(self, key: str) -> bool:
        return self.bucket(key).take()
```

| Setting | Default | Notes |
|---|---|---|
| `RATE_LIMIT_RPS` | 10 | Requests per second for each API key, refilled continuously |
| `RATE_LIMIT_BURST` | 20 | Bucket size |

> Note: this does not cover websockets.

We will leverage a very robust and battle-tested approach here.
