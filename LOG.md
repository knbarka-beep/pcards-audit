# Time and cost log

Same format as the other Assignment 1 cases.

## Time

Effective working time, excluding breaks and waiting on the API.

| Date | Task | Time (h) |
|---|---|---|
| 26.09.2026 | Case read-through, data checks, first version of queries and site (built with Claude) | 0,5 |
| 28.09.2026 | Running and reviewing queries, Gemini key, model fallback, GitHub, Streamlit deploy, assignment document | 2 |
| | **Total** | **2,5** |

## Cost

### Token cost per question (natural-language tab)

Measured in the app: about 528 input tokens and 90 to 130 output tokens per question.
Prices are Google's paid-tier list prices per 1M tokens (ai.google.dev/gemini-api/docs/pricing, checked 28.09.2026).

| Model | Input price | Output price | Cost per question | Cost per 1.000 questions |
|---|---|---|---|---|
| gemini-3.1-flash-lite (primary) | $0,25 | $1,50 | about $0,0003 | about $0,33 |
| gemini-3-flash (fallback) | $0,50 | $3,00 | about $0,0006 | about $0,65 |

Google AI Studio's usage page shows about 35 requests on the pcards-audit key, including failed
attempts (503 overloaded, 504 timeout, 404 model not available). At paid-tier prices that is about $0,01.
The key runs on the free tier, so the actual cost was $0. Newer Gemini models can also produce
internal "thinking" tokens that are billed as output and are not counted in the figures above,
so the real paid cost could be somewhat higher.

The dashboard tab uses no LLM and has no token cost.

### Other costs

| Item | Cost |
|---|---|
| Claude (coding assistant) | Covered by an existing Claude Pro subscription, no extra cost for this case |
| Gemini API | $0 (free tier) |
| Streamlit Community Cloud hosting | $0, free tier |
| GitHub | $0, free public repository |
| **Total extra cost** | **$0** |

## Notes

- Gemini response time varied from 1,6 s to over 200 s on 28.09.2026 because of overload on Google's side (HTTP 503).
  The app now tries a list of models in turn and gives up after 60 s instead of hanging.
- Adding domain hints to the prompt raised input tokens per question from about 415 to about 528,
  but fixed an incomplete answer (4 of 16 hotel transactions found before, 16 of 16 after).
