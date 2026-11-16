from __future__ import annotations

import sys

MESSAGE = """
A forecast run needs an administrator session, so it cannot be started from a
credential-free command line any more.

Start the dashboard (START.bat) and press Run Forecast on the Demand Forecast
page. The run reads the master product catalogue and the live order history as
you, and the page shows the period, the data cutoff and which products lack
enough history.
""".strip()


def main() -> int:
    print(MESSAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main())
