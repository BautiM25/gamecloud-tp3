import json
import os
import boto3
from boto3.dynamodb.conditions import Key

TABLE_NAME = os.environ.get("TABLE_NAME", "Puntajes")
AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table = dynamodb.Table(TABLE_NAME)

def handler(event, context):
    try:
        query_params = event.get("queryStringParameters") or {}
        juego_filtro = query_params.get("juego")

        if juego_filtro:
            juegos_a_consultar = [juego_filtro.lower()]
            resultado = {juego_filtro.lower(): []}
        else:
            juegos_a_consultar = ["doom", "pacman"]
            resultado = {"doom": [], "pacman": []}

        for juego in juegos_a_consultar:
            response = table.query(
                KeyConditionExpression=Key("juego").eq(juego)
            )
            items = response.get("Items", [])
            
            for item in items:
                item["puntaje"] = int(item["puntaje"])
            
            items_ordenados = sorted(items, key=lambda x: x["puntaje"], reverse=True)
            resultado[juego] = items_ordenados[:10]

        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*"
            },
            "body": json.dumps(resultado)
        }
    except Exception as e:
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": str(e)})
        }
