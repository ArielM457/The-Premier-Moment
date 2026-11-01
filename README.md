# **The Prime Moment**

**Demo:** <https://ca-mentoxp2-web.politegrass-7d829700.eastus2.azurecontainerapps.io>

The match with the MESSI stadium is `synthetic-live-001`, available in the Match tab of the Match Center. If the demo has been inactive, the first load may take a few seconds. Before stadium playback begins, TeamSpotting analyzes the video for approximately 3.5 minutes.

The Prime Moment is a monorepo for an experience that transforms football events into personalized moments and clear explanations. The [project documentation](docs/README.md) covers the scope, decisions, use cases, and event contract.

## **Event Data Lifecycle, Scalability, and Product Potential**

Each match begins as a continuous stream of video observations, ball and player positions, match events, viewer preferences, and editorial or community actions. MESSI, Roboflow, and TeamSpotting collect complementary information from the same authorized video, and every item is normalized into versioned contracts such as `MatchEvent v1` and `VisionObservation v1`. Each record keeps its match identifier, source identifier, event time, video time, confidence, and correlation data. Azure Event Hubs receives these streams, and the ingestion layer validates their schema, orders them, removes duplicates, reconciles late data, and synchronizes the match clock with the video clock before the information enters the intelligence core.

Every accepted event updates the reproducible match state, including the score, period, possession, timeline, statistics, play sequences, pressure, progressions, recoveries, shots, and detected situations. The analytics engine combines related signals, scores their relevance, and sends routine information directly to metrics while important events continue through context refinement, specialist agents, evidence verification, and presentation scheduling. Raw video and analysis artifacts are stored in Azure Blob Storage, while matches, normalized events, summaries, users, votes, messages, and editorial decisions are stored in PostgreSQL through Supabase. Verified metrics and insights return through Event Hubs, and FastAPI delivers them to the React application through REST, SSE, and WebSocket channels.

The model is scalable because streams are partitioned by `match_id`, processing services are stateless, and Container Apps can scale ingestion, analytics, agents, and delivery independently according to event volume and queue depth. Event Hubs handles high-throughput streams, while Service Bus adds priority, retries, expiration, idempotency, and dead-letter handling for important work without blocking routine match updates. This architecture is commercially strong because the same verified data pipeline can serve clubs, leagues, broadcasters, digital platforms, analysts, and fans through live explanations, personalized experiences, editorial tools, premium summaries, and B2B APIs. It turns one licensed data stream into several useful products while keeping every public explanation traceable to its evidence.

## **Diagrams and Business Model**

The three diagrams describe the target Azure architecture. The [What Runs in the Demo Today](#what-runs-in-the-demo-today) section identifies the components that are already deployed.

### **1. Event and Agent Flow**

![Event and agent flow](docs/images/flujo-eventos-y-agentes.png)

Every match event and control signal first passes through a deterministic filter without AI. The filter validates the schema, orders events, removes duplicates, updates metrics for every accepted event, detects play patterns, and selects a route:

- **Metrics only:** updates match state and metrics, which are published to Event Hubs through `match-metrics`. No agent is called.
- **Rejected or duplicate:** remains in an audit record.
- **Important event:** represents immediate danger, a candidate moment, a dead-ball context, or a period or match recap. The context refiner creates a request with only the required events, metrics, and preferences, then places it in Service Bus through `important-events`. The orchestrator processes it according to priority, time to live, and idempotency before sending it to the correct specialist: danger simulation, moment selection, narration, or recap.

Each agent response passes through evidence and fact verification, which compares it with the match state and metrics. Verified output is published to Event Hubs through `match-insights`, and the Experience API delivers it through REST and SSE to the live interface, recap, and editorial review. Solid lines represent direct flows, while dotted lines represent messaging.

### **2. Azure Architecture**

![Azure platform architecture](docs/images/arquitectura-en-azure.png)

The platform is organized into six layers:

1. **Live inputs:** video, match events, viewer preferences, and editorial and community actions.
2. **Ingestion and synchronization:** vision and tracking processing, API Management as the entry point, Event Hubs for match and vision streams, ordered and deduplicated validation, and synchronization between the video clock and match clock.
3. **Match intelligence core:** the state engine for score, possession, and timeline; the analytics engine for metrics, patterns, and situations; pre-agent routing; the agent layer for narration, moments, questions, and recaps; and the presentation scheduler for priority, timing, and personalization.
4. **Data and messaging:** Blob Storage for video, observations, and artifacts; Service Bus for important events; Event Hubs for routine events, metrics, and insights; and PostgreSQL for matches, events, users, and editorial data.
5. **Delivery:** the FastAPI service, real-time delivery through Server-Sent Events, and the React web application.
6. **User experience:** initial setup, the Match Center with Match, Recap, Statistics, and Tactical View, moment analysis, community and editorial review, and My Experience.

### **3. Azure Deployment**

![Azure deployment diagram](docs/images/despliegue-en-azure.png)

All components live within one resource group. Each flow component is deployed as a Container App in the same environment: the pre-filter for validation and routing, the context refiner, the orchestrator, four specialist agents, fact verification, and the Experience API. Service Bus stores important events between the refiner and orchestrator. Event Hubs `match-metrics` carries metrics to Cosmos DB, which stores match state. Event Hubs `match-insights` carries verified results to the API. Agents use AI Foundry models, secrets are stored in Key Vault, and telemetry is sent to Application Insights. The interface is published through Static Web Apps.

### **4. Business Model**

![The Prime Moment Business Model Canvas](docs/images/business-model-canvas.png)

The Prime Moment follows a B2B2C model. Paying customers are clubs, leagues, media organizations, and digital sports platforms, while end users include fans, analysts, and the general public. Its value proposition is to transform match data into clear stories, real-time explanations, highlights, and personalized, verifiable content. The canvas covers all nine areas:

- **Key partners:** data providers, clubs, leagues, rights holders, technology partners, and analytics experts.
- **Key activities and resources:** processing events, generating explanations, verifying sources, and measuring usage with an AI engine and licensed data.
- **Customer relationships and channels:** simple setup, on-demand explanations, personalized experiences, web and mobile applications, shareable content, and B2B APIs.
- **Costs:** data licenses, development, cloud services, moderation, sales, and operations.
- **Revenue:** B2B licenses, subscriptions with advanced features, premium content, API access, and tailored solutions.

### **What Runs in the Demo Today**

The demo is a reduced deployment of the full design and is released with [`infra/azure/deploy-analytics.ps1`](infra/azure/deploy-analytics.ps1):

- **Container Apps:** one FastAPI service contains the filter, orchestrator, agents, and verification process. The environment also runs the React interface through nginx, the continuous processor, which is off by default, and the job that replays matches.
- **Data and messaging:** Event Hubs carries match events, insights, and community-room activity. Blob Storage contains the MESSI video. The deployment also includes Container Registry, Log Analytics, and a managed identity. Service Bus exists, while the demo API currently routes agent work inside the application process.
- **Database:** Supabase PostgreSQL is the source of match data, and Supabase Auth validates editors.
- **Vision:** the stadium experience uses the MESSI simulator video with Roboflow and TeamSpotting.
- **Narration:** the deployed demo uses the provisional provider. Azure OpenAI is available locally with `NARRATIVE_PROVIDER=azure`.

API Management, Key Vault, Application Insights, Cosmos DB, AI Foundry, and Static Web Apps are not part of the current demo deployment, and the agents do not yet run in separate containers.

## **Repository Structure**

- `apps/frontend`: React interface written in JavaScript and built with Vite.
- `apps/backend`: FastAPI service written in Python and served with Uvicorn.
- `docs`: decisions, requirements, and research.
- `.agents/skills`: project instructions for future agents.

## **Codex and Context7**

The repository includes a Context7 configuration for consulting current library and framework documentation from Codex. Each contributor must authorize their own account. Keys and sessions are never shared.

Trust, authentication, verification, and troubleshooting instructions are available in [`.codex/README.md`](.codex/README.md).

## **Local Setup**

The project requires Python 3.12, [uv](https://docs.astral.sh/uv/), and a Node version compatible with Vite. `uv` can automatically install the version pinned in `.python-version`. From the repository root, run:

```bash
npm install
uv python install 3.12
uv sync --project apps/backend --extra dev
```

In one terminal, start the API with the local configuration from `apps/backend/.env`:

```bash
uv run --project apps/backend uvicorn match_intelligence.main:app --reload --app-dir apps/backend/src --env-file apps/backend/.env
```

First copy `apps/backend/.env.example` to `apps/backend/.env`. The real file is ignored by Git. Use `NARRATIVE_PROVIDER=provisional` to work without external services, `fixture` to test the Persona 3 contracts without Azure, or `azure` to use the configured deployments.

In another terminal, start the frontend:

```bash
npm run dev:frontend
```

The local interface is available at `http://localhost:5173`. Swagger UI is available at `http://localhost:8000/docs`. The interface plays synthetic matches with synchronized messages, preferences, questions, recaps, and editorial review. It can also simulate the six filter routes, review clip proposals, and inspect the flow from the analyst profile. The match experience can consume the Persona 3 module through the configured provider. See the [Persona 4 documentation](docs/persona-4-api-y-frontend/README.md) for details.

CrewAI is an optional backend dependency. Install it with `uv sync --project apps/backend --extra agents` to use the Azure OpenAI integration.

The Persona 3 module includes contracts, a narrative flow, and tests with a synthetic match. See the [agents and narrative guide](apps/backend/README-narrativa.md) to run it. The API exposes narrative operations through a synthetic test provider or Azure OpenAI when the resource and deployments are configured. The match-experience adapter uses the same flow without changing frontend contracts.

The backend also includes the first version of the event filter and agent routing. The `/api/v1/agent-routing/evaluate` route separates metrics-only events from relevant requests, recognizes two initial patterns, and prepares a reproducible dispatch. `POST /api/v1/matches/{match_id}/simulation` runs six synthetic scenarios. Durable storage and a production event channel for this route remain separate deployment steps.

The [Postman collection](postman/README.md) contains ready-to-import requests and tests.

## **Integrated Data and Vision Demonstration**

The integrated demonstration reuses the official backend and a technical validation interface. It does not modify the product frontend. It requires the authorized video and local exports from Roboflow Sports, SoccerNet, and DV-US-21.

```bash
UV_CACHE_DIR=/tmp/mentox-uv-cache \
uv run --project apps/backend --python 3.12 \
  uvicorn video_sync_diagnostic.app:app \
  --app-dir experiments --host 127.0.0.1 --port 8018
```

Open <http://127.0.0.1:8018>. The integrated API is available at `GET /api/v1/integration/status`, `GET /api/v1/integration/timeline`, and `/docs`.

With Docker:

```bash
docker-compose -f compose.integration.yml up --build
```

The video and results are mounted as read-only volumes and are not included in the image. For Azure, export the variables from `apps/backend/.env.example`. The default transport mode remains `memory`.

The interface controls the playback of previously calculated observations. Nothing is published until the user presses **Play**. Pause, seek, and restart update the backend cursor without presenting historical observations as new information.

To start the integrated test, run:

```bash
sudo docker-compose -f compose.integration.yml up --build
```

For Azure, export these variables first:

```bash
export VISION_OBSERVATION_TRANSPORT=azure_event_hubs
export EVENT_HUB_FULLY_QUALIFIED_NAMESPACE="<namespace>.servicebus.windows.net"
export VISION_EVENT_HUB_NAME="vision-observations"
export VISION_EVENT_HUB_CONSUMER_GROUP="backend"
```

The player instructs the backend to publish the crossed time range. In Azure, the backend produces observations through Event Hubs, its consumer receives and deduplicates them, and WebSocket delivery updates the interface. This test reuses calculated inference results and does not rerun the models.
