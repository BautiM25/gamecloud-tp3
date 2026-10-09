import json
import os
import boto3

QUEUE_URL = os.environ.get("QUEUE_URL")
AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

sqs = boto3.client("sqs", region_name=AWS_REGION)

def handler(event, context):
    try:
        body_raw = event.get("body")
        if body_raw is None:
            body_raw = "{}"
        if event.get("isBase64Encoded", False):
            import base64
            body_raw = base64.b64decode(body_raw).decode("utf-8")
        
        body = json.loads(body_raw) if isinstance(body_raw, str) else (body_raw or {})

        if not isinstance(body, dict):
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
                "body": json.dumps({"error": "Formato JSON inválido. Debe ser un objeto."})
            }

        jugador = body.get("jugador")
        juego = body.get("juego")
        puntaje = body.get("puntaje")

        if not jugador or not juego or puntaje is None or not isinstance(puntaje, int) or isinstance(puntaje, bool) or puntaje < 0:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
                "body": json.dumps({"error": "Datos inválidos. Se requiere jugador, juego y puntaje entero >= 0."})
            }

        juego_clean = str(juego).lower()
        if juego_clean not in ["doom", "pacman"]:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
                "body": json.dumps({"error": f"Juego '{juego}' no válido. Use 'doom' o 'pacman'."})
            }

        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps({
                "jugador": str(jugador),
                "juego": juego_clean,
                "puntaje": int(puntaje)
            })
        )

        return {
            "statusCode": 202,
            "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
            "body": json.dumps({"mensaje": "Puntaje encolado correctamente."})
        }
    except Exception as e:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
            "body": json.dumps({"error": "Formato JSON inválido."})
        }
