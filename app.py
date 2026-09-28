"""P-card audit site: natural-language query tab and prohibited-purchase dashboard.

Run locally:   streamlit run app.py
The Gemini key is read from .streamlit/secrets.toml locally and from the Secrets settings on
Streamlit Community Cloud. It is never written in this file or committed to Git.
"""
import json
import os
import re
import sqlite3
import time

import pandas as pd
import streamlit as st

from db import get_db_path

st.set_page_config(page_title="OSU P-card audit", layout="wide")

YEARS = [2014, 2013, 2012, 2011, 2010]
MAX_ROWS = 2000
QUERY_TIMEOUT_S = 20
GEMINI_TIMEOUT_S = 20      # per model call
GEMINI_TOTAL_BUDGET_S = 60  # whole question, all fallbacks included
TX_DATE = ("printf('%04d-%02d-%02d', Year, Month, "
           "CAST(substr(TransactionDate, instr(TransactionDate, '/') + 1) AS INTEGER))")

SCHEMA_TEXT = """Year INTEGER (transaction year), Month INTEGER (transaction month 1-12),
FullName TEXT (cardholder, e.g. 'Employee 5433B965'), ID INTEGER, AgencyNumber INTEGER (always 1000 = OSU),
AgencyName TEXT, CardholderLastName TEXT, CardholderFirstInitial TEXT, Description TEXT,
Amount REAL (US dollars; negative values are returns or credits), Vendor TEXT,
TransactionDate TEXT (format 'M/D/YYYY 0:00:00', not ISO), PostedDate TEXT (same format), MCC TEXT (merchant category name)"""

PROMPT = """You translate auditor questions into one safe SQLite query. The only approved table is:
pcards({schema})

Rules:
- Filter on Year = {year} unless the question explicitly asks for another year between 2010 and 2014.
- Use the Year and Month columns for year and month logic. TransactionDate and PostedDate are text in
  M/D/YYYY format, so to sort or compare by date use this ISO expression: {tx_date}
- Text matching is case-insensitive with LIKE. Use LIKE '%keyword%' for vendor, description or MCC searches.
- Returns are negative amounts. Say in the explanation whether returns were included.
- Domain hints: hotel or lodging stays have Description = 'ROOM CHARGES', and their MCC is often a hotel
  chain name (e.g. 'HAMPTON INNS', 'SHERATON', 'COURTYARD BY MARRIOTT') rather than the word HOTEL.
  Flights have Description = 'AIR TRAVEL'. Restaurants have MCC containing 'RESTAURANT' or 'EATING PLACES'.
  When searching for a category, match both Description and MCC so chain names are not missed.
- Round money to 2 decimals.
- Return exactly one SQLite SELECT statement (a WITH clause is allowed). Never query any table other than
  pcards. Do not use semicolons, PRAGMA, ATTACH, comments or any statement that writes or changes schema.

Return JSON with exactly these string keys:
- sql: the SQLite query
- explanation: one or two sentences on the period, filters, grouping and sorting used

Auditor question: {question}"""

FORBIDDEN = re.compile(
    r"\b(insert|update|delete|drop|alter|create|attach|detach|pragma|vacuum|reindex|analyze|trigger)\b",
    re.IGNORECASE,
)

# Keywords checked against the data: each one returns hits for at least one year.
PROHIBITED = {
    "Alcohol": "Description: alcohol, wine, beer. Vendor: liquor, wine, brew",
    "Cash, cash advances, ATM": "Description: cash. Vendor: cash, atm",
    "Decorations": "Description: decor, balloon. Vendor: party",
    "Donations and sponsorships": "Description: donation",
    "Gasoline": "Description: unleaded, fuel. Vendor: oncue, shell",
    "Gifts, gift cards, gift certificates": "Description: gift, flower. Vendor: gift, florist",
    "Insurance": "Description: insurance. Vendor: insurance",
    "Late fees": "Description: late, fee",
    "Mail and postage": "Description: stamp. Vendor: usps, post office",
    "Moving expenses": "Description: moving. Vendor: u-haul",
    "Personal purchases": "Description: personal. Vendor: netflix",
    "Memberships and dues": "Description: membership, dues. Vendor: club",
    "Salaries, wages, benefits": "Description: salary, wage",
    "Service and incentive awards": "Description: trophy, plaque, award. Vendor: award, trophy",
}


# ---------- database helpers ----------

@st.cache_resource(show_spinner="Preparing the database (first start only)...")
def db_path() -> str:
    return str(get_db_path())


def run_sql(sql: str, params: tuple = ()) -> pd.DataFrame:
    """Run a query on a read-only connection with a time limit."""
    con = sqlite3.connect(f"file:{db_path()}?mode=ro", uri=True)
    deadline = time.monotonic() + QUERY_TIMEOUT_S
    con.set_progress_handler(lambda: 1 if time.monotonic() > deadline else 0, 10_000)
    try:
        return pd.read_sql_query(sql, con, params=params)
    finally:
        con.close()


def check_sql(sql: str) -> str:
    """Reject anything that is not a single read-only SELECT on pcards. Returns the cleaned SQL."""
    sql = sql.strip().rstrip(";").strip()
    if ";" in sql:
        raise ValueError("More than one statement was returned.")
    if not re.match(r"^(select|with)\b", sql, re.IGNORECASE):
        raise ValueError("Only SELECT queries are allowed.")
    if FORBIDDEN.search(sql) or "--" in sql or "/*" in sql:
        raise ValueError("The query contains a keyword that is not allowed.")
    tables = re.findall(r"\b(?:from|join)\s+([A-Za-z_][A-Za-z0-9_]*)", sql, re.IGNORECASE)
    cte_names = {n.lower() for n in re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s+as\s*\(", sql, re.IGNORECASE)}
    unknown = {t.lower() for t in tables} - cte_names - {"pcards"}
    if unknown:
        raise ValueError(f"Only the pcards table may be queried (found: {', '.join(sorted(unknown))}).")
    return sql


# ---------- Gemini ----------

def gemini_key() -> str | None:
    try:
        key = st.secrets.get("GEMINI_API_KEY")
    except Exception:
        key = None
    return key or os.getenv("GEMINI_API_KEY")


DEFAULT_MODELS = "gemini-3.1-flash-lite-preview, gemini-flash-latest, gemini-3.5-flash-lite"
RETRYABLE = ("503", "unavailable", "429", "resource_exhausted", "504", "deadline", "timed out", "timeout")


def gemini_models() -> list[str]:
    """Models to try in order. GEMINI_MODEL in the secrets may hold one name or a comma-separated list."""
    try:
        value = st.secrets.get("GEMINI_MODEL")
    except Exception:
        value = None
    value = value or os.getenv("GEMINI_MODEL") or DEFAULT_MODELS
    return [m.strip() for m in value.split(",") if m.strip()]


def ask_gemini(question: str, year: int) -> dict:
    """Ask the first model that is available. If a model is overloaded (503), rate-limited (429)
    or too slow, move on to the next one instead of waiting."""
    from google import genai
    from google.genai import types

    # attempts=1 switches off the library's silent retries, which caused waits of several minutes
    # when a model was overloaded. The timeout stops any single call from freezing the page.
    client = genai.Client(
        api_key=gemini_key(),
        http_options=types.HttpOptions(
            timeout=GEMINI_TIMEOUT_S * 1000,
            retry_options=types.HttpRetryOptions(attempts=1),
        ),
    )
    prompt = PROMPT.format(schema=SCHEMA_TEXT, year=year, tx_date=TX_DATE, question=question)
    skipped = []
    reasons = {}
    # Two passes over the list: overload spikes are usually short, so a second pass a few
    # seconds later often succeeds without making the auditor press Run again.
    attempts = [(round_no, m) for round_no in (1, 2) for m in gemini_models()]
    budget_end = time.monotonic() + GEMINI_TOTAL_BUDGET_S
    for round_no, model in attempts:
        if time.monotonic() > budget_end:
            break
        if round_no == 2 and model == attempts[0][1]:
            time.sleep(3)
        start = time.perf_counter()
        try:
            response = client.models.generate_content(
                model=model,
                contents=prompt,
                config=types.GenerateContentConfig(
                    response_mime_type="application/json",
                    max_output_tokens=1024,
                    temperature=0,
                ),
            )
        except Exception as err:
            message = str(err).lower()
            if any(code in message for code in RETRYABLE):
                if model not in skipped:
                    skipped.append(model)
                reasons[model] = next(c for c in RETRYABLE if c in message)
                continue
            raise
        seconds = time.perf_counter() - start
        data = json.loads(response.text)
        usage = response.usage_metadata
        return {
            "sql": data.get("sql", ""),
            "explanation": data.get("explanation", ""),
            "model": model,
            "skipped": [m for m in skipped if m != model],
            "seconds": seconds,
            "tokens_in": getattr(usage, "prompt_token_count", None),
            "tokens_out": getattr(usage, "candidates_token_count", None),
            "tokens_total": getattr(usage, "total_token_count", None),
        }
    detail = ", ".join(f"{m}: {reasons[m]}" for m in skipped)
    raise RuntimeError(f"All configured Gemini models are busy right now ({detail}). "
                       "503 means Google is overloaded, 429 means the free-tier quota is used up. "
                       "Wait a minute and try again.")


# ---------- page ----------

st.title("OSU P-card audit")
st.caption("Oklahoma State University purchasing-card transactions, 2010 to 2014. "
           "Flagged transactions are potential exceptions for follow-up, not proof of a violation.")

tab_ask, tab_dash = st.tabs(["Ask the database", "Prohibited purchases dashboard"])

with tab_ask:
    st.subheader("Ask a question in plain English")
    st.caption("Models, tried in order: " + ", ".join(gemini_models()))
    st.write("Pick a year, type a question and press Run. Gemini writes one SQL query, the app checks it "
             "is read-only and runs it on the database. Always read the SQL before relying on the result: "
             "the model can misunderstand the question.")

    col_year, col_q = st.columns([1, 5])
    year_nl = col_year.selectbox("Year", YEARS, key="year_nl")
    question = col_q.text_input(
        "Question",
        placeholder="e.g. Which 10 cardholders spent the most at restaurants?",
    )
    with st.expander("Example questions"):
        st.markdown(
            "- Which 10 vendors received the most money?\n"
            "- How much was spent per month, returns excluded?\n"
            "- List all transactions over $5,000 at hotels, largest first.\n"
            "- Which cardholders made purchases on Christmas Day?"
        )

    if st.button("Run", type="primary"):
        if not question.strip():
            st.warning("Type a question first.")
        elif not gemini_key():
            st.error("No Gemini API key is configured. Add GEMINI_API_KEY to the app secrets.")
        else:
            try:
                with st.spinner("Asking Gemini..."):
                    answer = ask_gemini(question, year_nl)
                sql = check_sql(answer["sql"])
                df = run_sql(f"SELECT * FROM ({sql}) LIMIT {MAX_ROWS}")
            except Exception as err:
                st.error(f"The question could not be answered: {err}")
                if "answer" in locals():
                    st.code(answer.get("sql", ""), language="sql")
            else:
                st.markdown(f"**Explanation:** {answer['explanation']}")
                st.code(sql, language="sql")
                m1, m2, m3 = st.columns(3)
                m1.metric("Rows returned", f"{len(df):,}".replace(",", "."))
                m2.metric("Model response time", f"{answer['seconds']:.1f} s".replace(".", ","))
                m3.metric("Tokens (in / out)", f"{answer['tokens_in']} / {answer['tokens_out']}")
                note = f"Answered by {answer['model']}"
                if answer["skipped"]:
                    note += f" (skipped as busy: {', '.join(answer['skipped'])})"
                st.caption(note)
                if len(df) == MAX_ROWS:
                    st.info(f"Only the first {MAX_ROWS} rows are shown.")
                st.dataframe(df, width="stretch", hide_index=True)
                st.download_button("Download CSV", df.to_csv(index=False).encode("utf-8"),
                                   file_name="pcards_query.csv", mime="text/csv")

with tab_dash:
    st.subheader("Search for prohibited purchases")
    with st.expander("How to use this dashboard", expanded=True):
        st.markdown(
            "1. Choose the year to search.\n"
            "2. Use **Description search** to look for a word in what was bought "
            "(for example *alcohol* or *gift*).\n"
            "3. Use **Vendor search** to look for a word in who was paid "
            "(for example *usps* or *post office*).\n"
            "4. Matching is case-insensitive and finds the keyword anywhere in the field. "
            "Short keywords catch more but give more false positives (*gas* also matches *Vegas*).\n"
            "5. Review each hit and download the list for follow-up with the cardholder's approver."
        )
        st.markdown("**Prohibited categories and suggested keywords**")
        st.table(pd.DataFrame(
            [{"Prohibited category": k, "Suggested keywords": v} for k, v in PROHIBITED.items()]
        ))

    year_dash = st.selectbox("Year", YEARS, key="year_dash")

    def keyword_search(field: str, keyword: str) -> pd.DataFrame:
        escaped = keyword.strip().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        sql = f"""
            SELECT ID, Amount, FullName, Description, Vendor, TransactionDate, PostedDate, MCC
            FROM pcards
            WHERE AgencyNumber = ? AND Year = ?
              AND {field} IS NOT NULL
              AND {field} LIKE ? ESCAPE '\\'
            ORDER BY {TX_DATE} DESC, ID DESC
            LIMIT ?"""
        return run_sql(sql, (1000, year_dash, f"%{escaped}%", MAX_ROWS))

    def show_results(df: pd.DataFrame, label: str):
        if df.empty:
            st.info("No matching transactions.")
            return
        c1, c2 = st.columns(2)
        c1.metric("Transactions", f"{len(df):,}".replace(",", "."))
        total = f"${df['Amount'].sum():,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
        c2.metric("Total amount", total)
        if len(df) == MAX_ROWS:
            st.info(f"Only the first {MAX_ROWS} rows are shown. Use a more specific keyword.")
        st.dataframe(df, width="stretch", hide_index=True)
        st.download_button(f"Download {label} results (CSV)", df.to_csv(index=False).encode("utf-8"),
                           file_name=f"prohibited_{label}_{year_dash}.csv", mime="text/csv",
                           key=f"dl_{label}")

    left, right = st.columns(2)
    with left:
        st.markdown("### Description search")
        st.caption("Searches the transaction description field.")
        with st.form("desc_form"):
            desc_kw = st.text_input("Keyword in description", placeholder="e.g. alcohol")
            desc_go = st.form_submit_button("Search descriptions")
    with right:
        st.markdown("### Vendor search")
        st.caption("Searches the vendor (merchant) name field.")
        with st.form("vendor_form"):
            vend_kw = st.text_input("Keyword in vendor name", placeholder="e.g. post office")
            vend_go = st.form_submit_button("Search vendors")

    if desc_go:
        st.markdown(f"#### Description contains \"{desc_kw}\" ({year_dash})")
        if desc_kw.strip():
            show_results(keyword_search("Description", desc_kw), "description")
        else:
            st.warning("Enter a keyword.")
    if vend_go:
        st.markdown(f"#### Vendor contains \"{vend_kw}\" ({year_dash})")
        if vend_kw.strip():
            show_results(keyword_search("Vendor", vend_kw), "vendor")
        else:
            st.warning("Enter a keyword.")
