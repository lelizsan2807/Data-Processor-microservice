#!/bin/sh
set -eu

echo "Starting Data Processor..."
exec python3 app.py api --port 5000
