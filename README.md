# OSU P-card audit

Case 4 of Assignment 1, AI in Accounting and Business (SDU, autumn 2026).

An internal-audit toolkit over Oklahoma State University P-card transactions (2010 to 2014, 489.178 rows):

- `queries/part2_controls.sql`: the fourteen internal-control tests (Part II). Controls 1 to 7 are given in the case, 8 to 14 are my own, each derived from a rule in the Part I procedure.
- `queries/part3_fraud.sql`: the eight fraud tests (Part III), named `qry_T3_Question#`, with `Final` on the query that gives the final output.
- `run_queries.py`: runs every query and writes `results/<name>.csv` plus `results/summary.md`.
- `app.py`: the Part IV website (Streamlit). Tab 1 turns a plain-English question into SQL with Gemini and runs it read-only. Tab 2 is a prohibited-purchase dashboard with year selection and separate description and vendor keyword searches, using a fixed parameterised query and no LLM.

## Data notes

- Every row is OSU (AgencyNumber 1000), so only a Year filter is needed.
- Year and Month are the transaction year and month (checked: zero mismatches with TransactionDate).
- TransactionDate and PostedDate are text in `M/D/YYYY 0:00:00`. Sorting by date uses a rebuilt ISO date.
- Negative amounts are returns.
- `pcards.db` is 103 MB, above GitHub's 100 MB file limit. The repo holds `data/pcards.db.gz` (22 MB) and `db.py` unpacks it on first run.

## Run locally (Windows, cmd)

```
cd C:\Users\knbar\Documents\pcards-audit
py -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
py run_queries.py
copy .streamlit\secrets.toml.example .streamlit\secrets.toml
notepad .streamlit\secrets.toml
streamlit run app.py
```

## Deploy

Streamlit Community Cloud, main file `app.py`. The Gemini key goes in the app's Secrets settings, never in the repository.

## API key handling

The key is read from `st.secrets` (local `.streamlit/secrets.toml`, or the Secrets editor on Streamlit Cloud). `secrets.toml` and `.env` are in `.gitignore`. The browser only ever receives results, never the key.
