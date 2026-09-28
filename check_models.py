"""List the Gemini models this key can use and time one small call to each flash model.

Usage:  py check_models.py
Reads the key from .streamlit/secrets.toml. Prints response time or the error for each model.
"""
import time
import tomllib

from google import genai
from google.genai import types

key = tomllib.load(open(".streamlit/secrets.toml", "rb"))["GEMINI_API_KEY"]
# attempts=1 turns off the automatic retries, so an overloaded model shows up as an error at once.
client = genai.Client(
    api_key=key,
    http_options=types.HttpOptions(timeout=30_000, retry_options=types.HttpRetryOptions(attempts=1)),
)

models = []
for m in client.models.list():
    actions = getattr(m, "supported_actions", None) or []
    name = m.name.removeprefix("models/")
    if "generateContent" in actions and "flash" in name and "image" not in name and "tts" not in name \
            and "audio" not in name and "live" not in name:
        models.append(name)

print("Flash models available to this key:", ", ".join(models) or "none")
print()

for model in models[:8]:
    start = time.perf_counter()
    try:
        r = client.models.generate_content(
            model=model,
            contents="Reply with the single word OK.",
            config=types.GenerateContentConfig(max_output_tokens=20),
        )
        print(f"{model:32s} {time.perf_counter() - start:6.1f} s   reply: {(r.text or '').strip()[:20]}")
    except Exception as err:
        print(f"{model:32s} {time.perf_counter() - start:6.1f} s   ERROR: {str(err)[:110]}")
