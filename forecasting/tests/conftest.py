def pytest_addoption(parser):
    parser.addoption(
        "--update-goldens",
        action="store_true",
        default=False,
        help="Rewrite golden .expected.json files from current behaviour.",
    )
