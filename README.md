# GameCloud - Ranking Serverless en AWS (TP3 Aplicaciones en la Nube)

Implementación de una arquitectura serverless para publicación y gestión de rankings de videojuegos (Doom y Pac-Man) utilizando servicios gestionados de AWS emulados localmente con **MiniStack**.

---

##Arquitectura del Sistema

```
                     ┌────────────┐     ┌──────────────┐
  Jugador ──────────►│ CloudFront │────►│ S3 (web)     │
     │               └────────────┘     └──────────────┘
     │
     │  GET /ranking  ┌──────────────┐     ┌──────────┐
     ├───────────────►│ API Gateway  │────►│  Lambda  │──────┐
     │                │  (HTTP API)  │     │ ranking  │      │
     │  POST /scores  │              │     └──────────┘      ▼
     └───────────────►│              │     ┌──────────┐   ┌──────────┐
                      └──────────────┘────►│  Lambda  │   │ DynamoDB │
                                           │ recibir  │   │ Puntajes │
                                           └────┬─────┘   └──────────┘
                                                ▼              ▲
                       ┌──────────┐      ┌──────────┐    ┌─────┴────┐
                       │   DLQ    │◄─────│   SQS    │───►│  Lambda  │
                       └──────────┘  3x  │ puntajes │    │ procesar │
                                         └──────────┘    └──────────┘
```

### Componentes y Flujo
1. **Frontend Estático (S3 + CloudFront):** Archivos `index.html` y `config.js` servidos desde el bucket `gamecloud-web` con hosting estático y CDN CloudFront.
2. **API Gateway (HTTP API):** Expone las rutas públicas `GET /ranking` y `POST /scores` con CORS habilitado y throttling configurado (100 rps, ráfagas de 200).
3. **Lambda `recibir_puntaje`:** Valida sintaxis y tipos de datos del puntaje enviado, encola el evento en Amazon SQS y responde de forma inmediata `202 Accepted` sin tocar la base de datos.
4. **Cola SQS `puntajes` + DLQ:** Absorbe picos de tráfico desacoplando la ingesta. Si un mensaje falla 3 veces (`maxReceiveCount: 3`), se envía a `puntajes-dlq` tras expirar el Visibility Timeout (30s).
5. **Lambda `procesar_puntaje`:** Disparada por SQS (batch size: 5). Realiza persistencia idempotente en DynamoDB, actualizando el registro únicamente si el nuevo puntaje supera el récord histórico del jugador.
6. **DynamoDB `Puntajes`:** Almacenamiento NoSQL con clave compuesta `juego` (HASH) y `jugador` (RANGE) en modo `PAY_PER_REQUEST`.
7. **Lambda `ranking`:** Consulta DynamoDB mediante queries particionadas devolviendo el top 10 ordenado descendente por juego o filtrado con `?juego=doom`.

---

## Estructura del Repositorio

```
tp3-gamecloud/
├── docker-compose.yml          # Definición de contenedor MiniStack (puerto 4566)
├── iam/
│   ├── trust-lambda.json       # Trust relationship para el servicio Lambda
│   └── politica-lambdas.json   # Permisos de mínimo privilegio (DynamoDB, SQS, CloudWatch)
├── lambdas/
│   ├── ranking.py              # Handler de consulta y ordenamiento de rankings
│   ├── recibir_puntaje.py      # Handler de validación y encolado en SQS
│   └── procesar_puntaje.py     # Consumer de SQS con actualización condicional
├── scripts/
│   ├── deploy.sh               # Despliegue automatizado completo de la infraestructura
│   ├── test.sh                 # Suite de pruebas automatizadas obligatorias (Sección 6)
│   └── cleanup.sh              # Destrucción y limpieza de recursos locales
├── web/
│   └── index.html              # Frontend web provisto por la cátedra
├── README.md                   # Documentación técnica
└── .gitignore                  # Exclusiones de Git (zips, temporales, config.js)
```

---

##Requisitos Previos

- **Docker** y **Docker Compose**
- **AWS CLI** v2
- **bash**, **curl**, **zip** y **jq** (o `python3 -m json.tool`)

---

## Guía de Ejecución

### 1. Iniciar el emulador MiniStack

Levantar el contenedor con Docker Compose:

```bash
docker compose up -d
```

Configurar las credenciales y el alias local para AWS CLI:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1

alias awsl='aws --endpoint-url=http://localhost:4566'
```

Verificar que el emulador responde:

```bash
awsl s3 ls
```

### 2. Desplegar toda la infraestructura

Ejecutar el script automatizado:

```bash
chmod +x scripts/*.sh
./scripts/deploy.sh
```

El script se encarga de:
- Crear el bucket S3 y configurar hosting estático con `index.html`.
- Crear la distribución CloudFront.
- Crear la tabla DynamoDB `Puntajes`.
- Crear las colas SQS `puntajes-dlq` y `puntajes` con su RedrivePolicy.
- Crear el rol IAM y su política de permisos.
- Empaquetar y desplegar las 3 funciones Lambda con sus variables de entorno.
- Asociar el Event Source Mapping entre SQS y `procesar_puntaje`.
- Configurar API Gateway (HTTP API), integraciones, rutas, permisos y stage `$default` con throttling.
- Generar dinámicamente `web/config.js` con la URL de la API creada y sincronizarlo en S3.

### 3. Probar la aplicación en el navegador

Abrir en el navegador:

```
http://localhost:4566/gamecloud-web/index.html
```

Allí se visualizará el panel de rankings de Doom y Pac-Man y el formulario para registrar puntajes.

---

## Pruebas de la Arquitectura (Sección 6)

Para ejecutar de forma automatizada las 7 pruebas obligatorias del trabajo práctico:

```bash
./scripts/test.sh
```

### Pruebas individuales con cURL:

- **Registrar un puntaje válido (HTTP 202):**
  ```bash
  API_ID=$(awsl apigatewayv2 get-apis --query "Items[?Name=='gamecloud-api'].ApiId" --output text)
  curl -i -X POST "http://$API_ID.execute-api.localhost:4566/scores" \
    -H 'Content-Type: application/json' \
    -d '{"jugador":"ana","juego":"doom","puntaje":9800}'
  ```

- **Registrar puntaje con juego inválido (HTTP 400):**
  ```bash
  curl -i -X POST "http://$API_ID.execute-api.localhost:4566/scores" \
    -H 'Content-Type: application/json' \
    -d '{"jugador":"pedro","juego":"mario","puntaje":5000}'
  ```

- **Consultar rankings globales:**
  ```bash
  curl "http://$API_ID.execute-api.localhost:4566/ranking"
  ```

- **Consultar ranking filtrado por juego:**
  ```bash
  curl "http://$API_ID.execute-api.localhost:4566/ranking?juego=doom"
  ```

- **Verificar CloudWatch Logs de `procesar_puntaje`:**
  ```bash
  awsl logs filter-log-events --log-group-name "/aws/lambda/procesar_puntaje"
  ```

---

## Limpieza

Para eliminar todos los recursos creados en MiniStack:

```bash
./scripts/cleanup.sh
docker compose down
```
