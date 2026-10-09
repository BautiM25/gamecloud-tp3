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

echo "=========================================================="
echo "  Desplegando GameCloud en MiniStack ($ENDPOINT_URL)"
echo "=========================================================="

# 0. Verificar conectividad con MiniStack
if ! curl -s "$ENDPOINT_URL" > /dev/null 2>&1; then
  echo "Error: MiniStack no responde en $ENDPOINT_URL."
  echo "Inicie el contenedor con: docker compose up -d"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# 1. Frontend estático en S3 y CloudFront
echo "[1/5] Configurando S3 y CloudFront..."
awsl s3 mb s3://gamecloud-web 2>/dev/null || true
awsl s3 website s3://gamecloud-web --index-document index.html
awsl s3 cp web/index.html s3://gamecloud-web/index.html

echo "Creando distribución CloudFront..."
awsl cloudfront create-distribution \
  --origin-domain-name gamecloud-web.s3.amazonaws.com \
  --default-root-object index.html > /dev/null 2>&1 || true

# 2. Base de datos DynamoDB
echo "[2/5] Creando tabla DynamoDB 'Puntajes'..."
awsl dynamodb create-table \
  --table-name Puntajes \
  --attribute-definitions \
    AttributeName=juego,AttributeType=S \
    AttributeName=jugador,AttributeType=S \
  --key-schema \
    AttributeName=juego,KeyType=HASH \
    AttributeName=jugador,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST 2>/dev/null || true

awsl dynamodb wait table-exists --table-name Puntajes 2>/dev/null || true

# 3. Colas SQS (DLQ y Principal)
echo "[3/5] Configurando colas SQS..."
awsl sqs create-queue --queue-name puntajes-dlq > /dev/null 2>&1 || true

DLQ_ARN=$(awsl sqs get-queue-attributes \
  --queue-url "$ENDPOINT_URL/$ACCOUNT_ID/puntajes-dlq" \
  --attribute-names QueueArn \
  --query "Attributes.QueueArn" --output text)

REDRIVE_POLICY="{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}"

awsl sqs create-queue \
  --queue-name puntajes \
  --attributes "VisibilityTimeout=30,RedrivePolicy='$REDRIVE_POLICY'" > /dev/null 2>&1 || true

QUEUE_URL=$(awsl sqs get-queue-url --queue-name puntajes --query "QueueUrl" --output text)
QUEUE_ARN=$(awsl sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn \
  --query "Attributes.QueueArn" --output text)

# 4. IAM y Funciones Lambda
echo "[4/5] Configurando IAM y Funciones Lambda..."
ROLE_NAME="gamecloud-lambda-role"
ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"

awsl iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://iam/trust-lambda.json 2>/dev/null || true

awsl iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name gamecloud-lambda-policy \
  --policy-document file://iam/politica-lambdas.json

# Empaquetar Lambdas
(cd lambdas && zip -q -r ranking.zip ranking.py)
(cd lambdas && zip -q -r recibir_puntaje.zip recibir_puntaje.py)
(cd lambdas && zip -q -r procesar_puntaje.zip procesar_puntaje.py)

# Lambda: ranking
if awsl lambda get-function --function-name ranking >/dev/null 2>&1; then
  awsl lambda update-function-code --function-name ranking --zip-file fileb://lambdas/ranking.zip > /dev/null
  awsl lambda update-function-configuration --function-name ranking --environment "Variables={TABLE_NAME=Puntajes}" > /dev/null
else
  awsl lambda create-function \
    --function-name ranking \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler ranking.handler \
    --zip-file fileb://lambdas/ranking.zip \
    --environment "Variables={TABLE_NAME=Puntajes}" > /dev/null
fi

# Lambda: recibir_puntaje
if awsl lambda get-function --function-name recibir_puntaje >/dev/null 2>&1; then
  awsl lambda update-function-code --function-name recibir_puntaje --zip-file fileb://lambdas/recibir_puntaje.zip > /dev/null
  awsl lambda update-function-configuration --function-name recibir_puntaje --environment "Variables={QUEUE_URL=$QUEUE_URL}" > /dev/null
else
  awsl lambda create-function \
    --function-name recibir_puntaje \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler recibir_puntaje.handler \
    --zip-file fileb://lambdas/recibir_puntaje.zip \
    --environment "Variables={QUEUE_URL=$QUEUE_URL}" > /dev/null
fi

# Lambda: procesar_puntaje
if awsl lambda get-function --function-name procesar_puntaje >/dev/null 2>&1; then
  awsl lambda update-function-code --function-name procesar_puntaje --zip-file fileb://lambdas/procesar_puntaje.zip > /dev/null
  awsl lambda update-function-configuration --function-name procesar_puntaje --environment "Variables={TABLE_NAME=Puntajes}" > /dev/null
else
  awsl lambda create-function \
    --function-name procesar_puntaje \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler procesar_puntaje.handler \
    --zip-file fileb://lambdas/procesar_puntaje.zip \
    --environment "Variables={TABLE_NAME=Puntajes}" > /dev/null
fi

# Event Source Mapping (SQS -> procesar_puntaje)
EXISTING_MAPPING=$(awsl lambda list-event-source-mappings \
  --function-name procesar_puntaje \
  --query "EventSourceMappings[?EventSourceArn=='$QUEUE_ARN'].UUID" --output text)

if [ -z "$EXISTING_MAPPING" ] || [ "$EXISTING_MAPPING" == "None" ]; then
  awsl lambda create-event-source-mapping \
    --function-name procesar_puntaje \
    --event-source-arn "$QUEUE_ARN" \
    --batch-size 5 > /dev/null
fi

# 5. API Gateway (HTTP API)
echo "[5/5] Configurando API Gateway..."
EXISTING_API_ID=$(awsl apigatewayv2 get-apis \
  --query "Items[?Name=='gamecloud-api'].ApiId" --output text)

if [ -n "$EXISTING_API_ID" ] && [ "$EXISTING_API_ID" != "None" ]; then
  API_ID="$EXISTING_API_ID"
else
  API_ID=$(awsl apigatewayv2 create-api \
    --name gamecloud-api \
    --protocol-type HTTP \
    --cors-configuration "AllowOrigins=*,AllowMethods=GET,POST,OPTIONS,AllowHeaders=Content-Type" \
    --query "ApiId" --output text)
fi

# Integraciones
INT_RANKING_ID=$(awsl apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:lambda:$REGION:$ACCOUNT_ID:function:ranking" \
  --payload-format-version "2.0" \
  --query "IntegrationId" --output text 2>/dev/null || \
  awsl apigatewayv2 get-integrations --api-id "$API_ID" --query "Items[0].IntegrationId" --output text)

INT_RECIBIR_ID=$(awsl apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:lambda:$REGION:$ACCOUNT_ID:function:recibir_puntaje" \
  --payload-format-version "2.0" \
  --query "IntegrationId" --output text 2>/dev/null || \
  awsl apigatewayv2 get-integrations --api-id "$API_ID" --query "Items[1].IntegrationId" --output text)

# Rutas
awsl apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "GET /ranking" \
  --target "integrations/$INT_RANKING_ID" 2>/dev/null || true

awsl apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "POST /scores" \
  --target "integrations/$INT_RECIBIR_ID" 2>/dev/null || true

# Permisos para API Gateway invocar Lambdas
awsl lambda add-permission \
  --function-name ranking \
  --statement-id "apigateway-get-ranking" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*" 2>/dev/null || true

awsl lambda add-permission \
  --function-name recibir_puntaje \
  --statement-id "apigateway-post-scores" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*" 2>/dev/null || true

# Stage $default con Throttling
awsl apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name '$default' \
  --auto-deploy \
  --default-route-settings "ThrottlingBurstLimit=200,ThrottlingRateLimit=100" 2>/dev/null || \
awsl apigatewayv2 update-stage \
  --api-id "$API_ID" \
  --stage-name '$default' \
  --default-route-settings "ThrottlingBurstLimit=200,ThrottlingRateLimit=100" 2>/dev/null || true

# Configuración Web Frontend
API_ENDPOINT="http://$API_ID.execute-api.localhost:4566"
echo "window.GAMECLOUD_API = \"$API_ENDPOINT\";" > web/config.js
awsl s3 cp web/config.js s3://gamecloud-web/config.js

echo ""
echo "=========================================================="
echo "  Despliegue completado con éxito!"
echo "=========================================================="
echo "Frontend S3:      $ENDPOINT_URL/gamecloud-web/index.html"
echo "API ID:           $API_ID"
echo "API Endpoint:     $API_ENDPOINT"
echo "Consultar ranking: curl $API_ENDPOINT/ranking"
echo "=========================================================="
