# Region registration regression tests

Run from the repository root with Python 3.10+, Helm 3, jq, and base64 available:

```sh
python3 -m venv /tmp/daytona-region-tests
/tmp/daytona-region-tests/bin/pip install -r tests/daytona-region/requirements.txt
/tmp/daytona-region-tests/bin/python -B -m unittest discover -s tests/daytona-region -v
helm lint charts/daytona-region --strict -f charts/daytona-region/tests/fixtures/baseline.values.yaml
bash scripts/_lib/check/check-baseline-compat.sh
```

The tests render the actual hook and execute its shell with fake `curl` and
`kubectl` commands and synthetic credentials. They cover opt-out behavior,
creation, upgrade, explicit reset, API failures, missing region IDs, payload
escaping, and snapshot credential recovery. They make no network or cluster
requests and do not verify telemetry delivery.

With the helm-unittest plugin installed, also run the rendering assertions:

```sh
helm unittest --strict --with-subchart=false -f 'tests/region-registration_test.yaml' charts/daytona-region
```

For deployment validation, follow the chart README's sandbox telemetry section
and confirm metrics arrive from a new BYOC sandbox in the configured backend.
