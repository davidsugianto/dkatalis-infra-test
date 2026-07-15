#!/usr/bin/env bash
set -euo pipefail

ES_URL="https://13.212.214.58:9200"
ES_USER="elastic"
ES_PASS="$(yq -r '.elastic_password' inventories/aws/main/ap-southeast-1/production/group_vars/tag_Hostgroup_es_node | ansible-vault decrypt)"
CURL="curl -sk -u $ES_USER:$ES_PASS"

echo "=== 1. Connectivity ==="
echo $CURL
$CURL "$ES_URL/" | grep -q "You Know, for Search" && echo "OK" || { echo "FAIL"; exit 1; }

echo "=== 2. Cluster health ==="
STATUS=$($CURL "$ES_URL/_cluster/health" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
echo "Status: $STATUS"
[ "$STATUS" != "red" ] || { echo "FAIL: cluster is red"; exit 1; }

echo "=== 3. Write test ==="
$CURL -X POST "$ES_URL/healthcheck-test/_doc/1" \
  -H 'Content-Type: application/json' \
  -d '{"check":"ok"}' | grep -q '"result":"created"\|"result":"updated"' && echo "OK" || { echo "FAIL"; exit 1; }

echo "=== 4. Read test ==="
$CURL "$ES_URL/healthcheck-test/_doc/1" | grep -q '"found":true' && echo "OK" || { echo "FAIL"; exit 1; }

echo "=== 5. Search test ==="
$CURL -X POST "$ES_URL/healthcheck-test/_refresh" > /dev/null
$CURL "$ES_URL/healthcheck-test/_search?q=check:ok" | grep -q '"value":1' && echo "OK" || { echo "FAIL"; exit 1; }

echo "=== 6. Cleanup ==="
$CURL -X DELETE "$ES_URL/healthcheck-test" > /dev/null && echo "OK"

echo ""
echo "=== ALL CHECKS PASSED ==="