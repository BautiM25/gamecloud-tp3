import json
import os
import boto3

TABLE_NAME = os.environ.get("TABLE_NAME", "Puntajes")
AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table = dynamodb.Table(TABLE_NAME)

def handler(event, context):
    procesados = 0
    for record in event.get("Records", []):
        body_str = record.get("body", "")
        # Si el body no es un JSON válido, lanzará un ValueError/DecodeError,
        # provocando fallo para que SQS reintente y envíe a la DLQ.
        data = json.loads(body_str)

        jugador = str(data["jugador"])
        juego = str(data["juego"]).lower()
        puntaje = int(data["puntaje"])

        res = table.get_item(Key={"juego": juego, "jugador": jugador})
        item = res.get("Item")

        if item:
            puntaje_actual = int(item.get("puntaje", 0))
            if puntaje > puntaje_actual:
                table.put_item(Item={"juego": juego, "jugador": jugador, "puntaje": puntaje})
                print(f"Récord actualizado: {jugador} en {juego} con {puntaje} pts (anterior: {puntaje_actual})")
            else:
                print(f"Puntaje ignorado: {jugador} en {juego} ({puntaje} pts <= {puntaje_actual} pts)")
        else:
            table.put_item(Item={"juego": juego, "jugador": jugador, "puntaje": puntaje})
            print(f"Nuevo registro: {jugador} en {juego} con {puntaje} pts")

        procesados += 1

    return {"procesados": procesados}
