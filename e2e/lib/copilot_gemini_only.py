import os
import sys
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.voice.dashboard_llm.server import app  # noqa: E402

app.firebase_verifier = lambda project: lambda token: {"sub": "e2e-copilot"}
app.firestore_access_check = lambda project: lambda token, uid: True

state = app._configured_state()
ThreadingHTTPServer(
    (os.environ["COPILOT_HOST"], int(os.environ["PORT"])), app.make_handler(state)
).serve_forever()
