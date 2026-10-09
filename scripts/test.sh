#!/usr/bin/env bash
set -eo pipefail

ENDPOINT_URL="http://localhost:4566"
REGION="us-east-1"
ACCOUNT_ID="000000000000"

export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="$REGION"

awsl() {
  aws --endpoint-url="$ENDPOINT_URL" --region="$REGION" "$@"
}

API_ID=$(awsl apigatewayv2 get-apis --query "Items[?Name=='gamecloud-api'].ApiId" --output text)
if [ -z "$API_ID" ] || [ "$API_ID" == "None" ]; then
  echo "Error: gamecloud-api no encontrada. Ejecute scripts/deploy.sh primero."
  exit 1
fi

API_URL="http://$API_ID.execute-api.localhost:4566"
QUEUE_URL="$ENDPOINT_URL/$ACCOUNT_ID/puntajes"
DLQ_URL="$ENDPOINT_URL/$ACCOUNT_ID/puntajes-dlq"

echo "=========================================================="
echo "  Ejecutando Pruebas de la Arquitectura (Sección 6)"
echo "  API Target: $API_URL"
echo "=========================================================="

echo ""
echo "[Prueba 1] Enviando 5 puntajes válidos (esperado: 202 Accepted)..."
curl -s -i -X POST "$API_URL/scores" -H "Content-Type: application/json" -d '{"jugador":"ana","juego":"doom","puntaje":9800}' | head -n 1
curl -s -i -X POST "$API_URL/scores" -H "Content-Type: application/json" -d '{"jugador":"carlos","juego":"doom","puntaje":8500}' | head -n 1
curl -s -i -X POST "$API_URL/scores" -H "Content-Type: application/json" -d '{"jugador":"lucia","juego":"pacman","puntaje":12000}' | head -n 1
curl -s -i -X POST "$API_URL/scores" -H "Content-Type: application/json" -d '{"jugador":"martin","juego":"pacman","puntaje":9500}' | head -n 1
curl -s -i -X POST "$API_URL/scores" -H "Content-Type: application/json" -d '{"jugador":"sofia","juego":"doom","puntaje":11200}' | head -n 1

echo ""
echo "[Prueba 2] Enviando puntaje con juego inexistente (esperado: 400 Bad Request)..."
curl -s -i -X POST "$API_URL/scores" -H "Content-Type: application/json" -d '{"jugador":"pedro","juego":"tetris","puntaje":5000}' | head -n 1

echo ""
echo "[Prueba 3] Enviando puntaje menor al actual de 'ana' (doom: 5000 < 9800)..."
curl -s -i -X POST "$API_URL/scores" -H "Content-Type: application/json" -d '{"jugador":"ana","juego":"doom","puntaje":5000}' | head -n 1

echo "Esperando 4 segundos para procesamiento asíncrono..."
sleep 4

echo ""
echo "[Prueba 4a] Consultando GET /ranking completo:"
curl -s "$API_URL/ranking" | json_pp 2>/dev/null || curl -s "$API_URL/ranking"
echo ""

echo ""
echo "[Prueba 4b] Consultando GET /ranking?juego=doom filtrado:"
curl -s "$API_URL/ranking?juego=doom" | json_pp 2>/dev/null || curl -s "$API_URL/ranking?juego=doom"
echo ""

echo ""
echo "[Prueba 5] Simulación de pico de tráfico (50 puntajes en paralelo)..."
for i in $(seq 1 50); do
  curl -s -X POST "$API_URL/scores" \
    -H "Content-Type: application/json" \
    -d "{\"jugador\":\"bot_$i\",\"juego\":\"doom\",\"puntaje\":$((i * 100))}" > /dev/null &
done

echo "Consultando métricas de cola SQS durante el pico:"
awsl sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible

echo "Esperando a que la Lambda procese los mensajes..."
wait
sleep 6

echo "Estado de la cola tras procesamiento:"
awsl sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible

echo ""
echo "[Prueba 6] Mensaje inválido (no JSON) directo a SQS para verificar DLQ..."
awsl sqs send-message \
  --queue-url "$QUEUE_URL" \
  --message-body "MENSAJE_CORRUPTO_NO_JSON" > /dev/null

echo "Esperando reintentos (maxReceiveCount=3 con visibility timeout)..."
# MiniStack procesa casi inmediato o tras reintentos
sleep 10

echo "Verificando mensajes en puntajes-dlq:"
awsl sqs get-queue-attributes \
  --queue-url "$DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages

echo ""
echo "[Prueba 7] Consultando CloudWatch Logs de 'procesar_puntaje'..."
LOG_GROUP="/aws/lambda/procesar_puntaje"
awsl logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --limit 10 \
  --query "events[*].message" --output text 2>/dev/null || echo "Logs aún no disponibles o sin eventos registrados."

echo ""
echo "=========================================================="
echo "  Pruebas finalizadas!"
echo "=========================================================="
