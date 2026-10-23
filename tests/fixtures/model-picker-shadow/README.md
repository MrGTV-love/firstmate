# Shadow model picker fixtures

The projection files here are reduced copies of real Artificial Analysis projections from
`data/model-picker/projection/` (2026-10-16 snapshot, verdict TRUSTED, 0 mismatches in 6762
compared values). Only the metrics the picker demands and the cost/token rows are kept; every
value is the source file's own value, not an invented one.

| Fixture | Source projection |
| --- | --- |
| `claude-sonnet-5-5-high.json` | `data/model-picker/projection/claude-sonnet-5-5-high.json` |
| `claude-opus-5-5-high.json` | `data/model-picker/projection/claude-opus-5-5-high.json` |
| `claude-haiku-5-5.json` | `data/model-picker/projection/claude-haiku-5-5.json` |
| `gpt-6-1-sol-high.json` | `data/model-picker/projection/gpt-6-1-sol-high.json` |
| `gpt-6-luna-low.json` | `data/model-picker/projection/gpt-6-luna-low.json` |
| `deepseek-v4-flash.json` | `data/model-picker/projection/deepseek-v4-flash.json` |

The tests copy these files into a throwaway data root; they never read or write the real
`data/model-picker/` directory.
