#!/usr/bin/env bash
set -e

PORT=3004
DIR="$(cd "$(dirname "$0")" && pwd)"

fuser -k ${PORT}/tcp 2>/dev/null || true
pkill -f "ngrok http" 2>/dev/null || true

python3 -m http.server ${PORT} --directory "${DIR}" &
HTTP_PID=$!
echo "HTTP server PID ${HTTP_PID} on port ${PORT}"

sleep 1

ngrok http ${PORT} --log=stdout > /tmp/ngrok-kube-vllm.log 2>&1 &
NGROK_PID=$!
echo "ngrok PID ${NGROK_PID}"

echo "Waiting for ngrok tunnel..."
URL=""
for i in $(seq 1 20); do
  RAW=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null || true)
  if [ -n "${RAW}" ]; then
    URL=$(echo "${RAW}" | python3 -c "import sys,json; t=json.load(sys.stdin).get('tunnels',[]); print(next((x['public_url'] for x in t if x['public_url'].startswith('https')), ''))" 2>/dev/null || true)
  fi
  if [ -n "${URL}" ]; then
    break
  fi
  sleep 1
done

if [ -z "${URL}" ]; then
  echo "ERROR: ngrok tunnel did not come up. Check /tmp/ngrok-kube-vllm.log"
  exit 1
fi

echo ""
echo "==============================================="
echo "  kube-vLLM docs — public URL:"
echo "  ${URL}"
echo "==============================================="
echo ""
echo "Press Ctrl+C to stop."

trap "kill ${HTTP_PID} ${NGROK_PID} 2>/dev/null; echo 'Stopped.'" EXIT INT TERM
wait
