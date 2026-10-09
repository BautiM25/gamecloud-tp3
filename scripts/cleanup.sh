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

echo "Limpiando recursos de GameCloud en MiniStack..."

# API Gateway
API_ID=$(awsl apigatewayv2 get-apis --query "Items[?Name=='gamecloud-api'].ApiId" --output text 2>/dev/null || true)
if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  awsl apigatewayv2 delete-api --api-id "$API_ID" || true
fi

# Event source mappings
MAPPINGS=$(awsl lambda list-event-source-mappings --function-name procesar_puntaje --query "EventSourceMappings[*].UUID" --output text 2>/dev/null || true)
for m in $MAPPINGS; do
  awsl lambda delete-event-source-mapping --uuid "$m" || true
done

# Lambdas
for fn in ranking recibir_puntaje procesar_puntaje; do
  awsl lambda delete-function --function-name "$fn" 2>/dev/null || true
done

# SQS
awsl sqs delete-queue --queue-url "$ENDPOINT_URL/$ACCOUNT_ID/puntajes" 2>/dev/null || true
awsl sqs delete-queue --queue-url "$ENDPOINT_URL/$ACCOUNT_ID/puntajes-dlq" 2>/dev/null || true

# DynamoDB
awsl dynamodb delete-table --table-name Puntajes 2>/dev/null || true

# S3
awsl s3 rb s3://gamecloud-web --force 2>/dev/null || true

# IAM
awsl iam delete-role-policy --role-name gamecloud-lambda-role --policy-name gamecloud-lambda-policy 2>/dev/null || true
awsl iam delete-role --role-name gamecloud-lambda-role 2>/dev/null || true

# Temp files
rm -f lambdas/*.zip web/config.js

echo "Limpieza completada."
