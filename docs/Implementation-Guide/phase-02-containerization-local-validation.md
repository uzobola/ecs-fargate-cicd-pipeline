## Phase 2: Containerization and Local Integration Validation

### Purpose

This phase packages the supplied React frontend and Express backend as separate
container images, verifies each container independently, then tests both through
a temporary local router that reproduces the planned AWS Application Load
Balancer path rules.

The temporary router is used only for local validation. It is not part of the
deployed AWS architecture.

### Acceptance criteria

Phase 2 passes when all of the following are proven:

- The backend image builds from its committed dependency lock file.
- The backend starts successfully under a non-root user.
- `GET /health` returns HTTP 200 with `{"status":"ok"}`.
- `GET /api` returns HTTP 200 with a GUID.
- The configured CORS origin appears in the backend response.
- The frontend image builds successfully.
- The final frontend image runs Nginx rather than Node.js.
- Nginx runs under a non-root user.
- `/` returns the compiled React application.
- Unknown frontend routes return `index.html`.
- A browser request through the local router displays `SUCCESS: <guid>`.

---

## 2.1 Prerequisites

Note: Run all commands from the repository root:

Confirm Docker is available:

```bash
# Display both the Docker client and Docker engine versions.
docker version
```

Expected result:

```text
Client:
...

Server:
...
```

Confirm the Docker engine is responding:

```bash
# This must complete without a permission or connection error.
docker ps
```

For a Windows and WSL workstation, Docker Desktop must be running and WSL
integration must be enabled for the Linux distribution containing this
repository.

---

## 2.2 Build the backend image

The backend image uses:

- Node.js 24 on Alpine Linux
- Production-only npm dependencies
- The committed `package-lock.json`
- The built-in non-root `node` account
- Port `8080`

Build the image:

```bash
# --pull checks for the current version of the selected base-image tag.
# --no-cache proves the image can build without previously cached layers.
# -t assigns a local name and tag to the completed image.
# ./backend sets the Docker build context.
docker build \
  --pull \
  --no-cache \
  -t tc1-backend:phase2 \
  ./backend
```

Expected final output includes:

```text
RUN npm ci --omit=dev
COPY --chown=node:node index.js config.js ./
exporting to image
naming to docker.io/library/tc1-backend:phase2
```

Confirm that the image exists locally:

```bash
docker image ls tc1-backend:phase2
```

Expected result:

```text
REPOSITORY      TAG       IMAGE ID       CREATED
tc1-backend     phase2    <image-id>     <time>
```

This step creates a local image only. It does not push the image to Docker Hub
or Amazon ECR.

---

## 2.3 Create the local integration network

Create one user-defined Docker network for the frontend, backend, and temporary
router:

```bash
# Reuse the network when it already exists.
docker network inspect tc1-net >/dev/null 2>&1 \
  || docker network create tc1-net
```

Confirm the network exists:

```bash
docker network ls --filter name=tc1-net
```

A user-defined network permits container-name DNS resolution. The router can
reach the backend through `tc1-backend:8080` and the frontend through
`tc1-frontend:3000`.

---

## 2.4 Run the backend container

Remove any earlier test container:

```bash
# Ignore the error when no earlier container exists.
docker rm -f tc1-backend 2>/dev/null || true
```

Start the backend:

```bash
# -d runs the container in the background.
# --name assigns a stable container name.
# --network places the container on the shared test network.
# -p publishes host port 8080 to container port 8080.
# CORS_ORIGIN defines the browser origin permitted by the CORS response.
docker run -d \
  --name tc1-backend \
  --network tc1-net \
  -p 8080:8080 \
  -e CORS_ORIGIN=http://localhost:8088 \
  tc1-backend:phase2
```

Docker returns a container ID when creation succeeds.

Confirm that the container remains running:

```bash
docker ps --filter name=tc1-backend
```

Expected result includes:

```text
STATUS
Up ...

PORTS
0.0.0.0:8080->8080/tcp
```

Inspect startup logs:

```bash
docker logs tc1-backend
```

Expected output:

```text
Backend started on 8080. ctrl+c to exit
```

No exception or crash stack should appear.

---

## 2.5 Verify the backend

### Health endpoint

```bash
curl -i http://localhost:8080/health
```

Expected result:

```text
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8
```

Expected body:

```json
{"status":"ok"}
```

This endpoint will later serve as the Application Load Balancer target-group
health-check path.

### Application endpoint

```bash
curl -i http://localhost:8080/api
```

Expected result:

```text
HTTP/1.1 200 OK
```

Expected body shape:

```json
{"id":"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}
```

The GUID value changes when the backend process is recreated.

### CORS configuration

```bash
curl -i \
  -H "Origin: http://localhost:8088" \
  http://localhost:8080/api
```

Expected response header:

```text
Access-Control-Allow-Origin: http://localhost:8088
```

This proves that the runtime environment variable reached the Express
application.

CORS does not prevent direct requests made through tools such as `curl`.
Browsers enforce whether JavaScript from another origin may read the response.

### Negative CORS verification

```bash
curl -i \
  -H "Origin: https://untrusted.example" \
  http://localhost:8080/api
```

The response must not contain:

```text
Access-Control-Allow-Origin: https://untrusted.example
```

The current application returns the configured origin:

```text
Access-Control-Allow-Origin: http://localhost:8088
```

A browser page running from the untrusted origin cannot read that response.

### Non-root runtime verification

Inspect the configured runtime user:

```bash
docker inspect \
  --format 'Configured user: {{.Config.User}}' \
  tc1-backend
```

Expected result:

```text
Configured user: node
```

Inspect the identity inside the running container:

```bash
docker exec tc1-backend id
```

Expected result:

```text
uid=1000(node) gid=1000(node) groups=1000(node)
```

Inspect the live process:

```bash
docker top tc1-backend -eo user,pid,comm,args
```

The Node process must not run under UID `0` or the `root` account.

---

## 2.6 Build the frontend image

The frontend uses a multi-stage build:

1. Node.js 16.20.2 compiles the supplied React application.
2. The compiled static files are copied into an unprivileged Nginx image.
3. Node.js is absent from the final frontend runtime image.

Build the image:

```bash
docker build \
  --pull \
  --no-cache \
  -t tc1-frontend:phase2 \
  ./frontend
```

Expected final output includes:

```text
FROM docker.io/library/node:16.20.2-alpine
RUN npm ci --legacy-peer-deps
RUN npm run build
COPY --from=build /app/build /usr/share/nginx/html
FROM nginxinc/nginx-unprivileged:alpine
exporting to image
```

Confirm that the image exists:

```bash
docker image ls tc1-frontend:phase2
```

Expected result:

```text
REPOSITORY       TAG       IMAGE ID       CREATED
tc1-frontend     phase2    <image-id>     <time>
```

---

## 2.7 Run the frontend container

Remove any earlier test container:

```bash
docker rm -f tc1-frontend 2>/dev/null || true
```

Start the frontend:

```bash
# Port 3000 is used by the unprivileged Nginx server in this image.
docker run -d \
  --name tc1-frontend \
  --network tc1-net \
  -p 3000:3000 \
  tc1-frontend:phase2
```

Confirm that the container remains running:

```bash
docker ps --filter name=tc1-frontend
```

Expected result includes:

```text
STATUS
Up ...

PORTS
0.0.0.0:3000->3000/tcp
```

Inspect the startup logs:

```bash
docker logs tc1-frontend
```

Expected output includes:

```text
Configuration complete; ready for start up
start worker processes
```

The entrypoint may report that it cannot modify the read-only
`default.conf`. This is expected when the supplied configuration is mounted or
copied as an immutable file. Nginx must still start and remain running.

---

## 2.8 Verify the frontend

### Root route

```bash
curl -i http://localhost:3000/
```

Expected result:

```text
HTTP/1.1 200 OK
Content-Type: text/html
```

The response body should contain the compiled React HTML.

### SPA fallback

```bash
curl -i http://localhost:3000/test-route
```

Expected result:

```text
HTTP/1.1 200 OK
Content-Type: text/html
```

The response should return the same React `index.html` document. This proves the
Nginx rule below is working:

```nginx
try_files $uri /index.html;
```

### Non-root runtime verification

Inspect the configured user:

```bash
docker inspect \
  --format 'Configured user: {{.Config.User}}' \
  tc1-frontend
```

Expected result:

```text
Configured user: 101
```

Inspect the identity inside the container:

```bash
docker exec tc1-frontend id
```

Expected result:

```text
uid=101(nginx) gid=101(nginx)
```

Inspect the live Nginx processes:

```bash
docker top tc1-frontend -eo user,pid,comm,args
```

The Nginx master and worker processes must not run under UID `0`.

Some host systems display another username for UID `101`. The numeric UID is
the authoritative value. Inside this container, UID `101` is the Nginx account.

---

## 2.9 Confirm both containers are on the shared network

```bash
docker network inspect tc1-net \
  --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}'
```

Expected names:

```text
tc1-backend
tc1-frontend
```

If a container is missing, connect it:

```bash
docker network connect tc1-net tc1-backend
docker network connect tc1-net tc1-frontend
```

Docker may report that the endpoint already exists when the container is
already connected.

---

## 2.10 Create the temporary local router

The production frontend bundle calls the relative path:

```text
/api
```

A browser opened directly at `http://localhost:3000` sends that request back to
the frontend Nginx container. The planned AWS Application Load Balancer will
route `/api` to the backend service.

The temporary router below reproduces that behavior locally:

```text
/       -> frontend container
/api    -> backend container
```

Create the temporary Nginx server configuration:

```bash
cat > /tmp/tc1-router.conf <<'EOF'
server {
    listen 8088;
    server_name _;

    # Forward API requests to the Express backend.
    location /api {
        proxy_pass http://tc1-backend:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # Send every other request to the React frontend.
    location / {
        proxy_pass http://tc1-frontend:3000;
        proxy_set_header Host $host;
    }
}
EOF
```

This file is created under `/tmp` and is not committed to the repository.

---

## 2.11 Run the temporary router

Remove an earlier router container:

```bash
docker rm -f tc1-router 2>/dev/null || true
```

Start the router:

```bash
# The temporary file replaces only the default server block.
# The image's main nginx.conf remains unchanged.
# :ro mounts the server configuration as read-only.
docker run -d \
  --name tc1-router \
  --network tc1-net \
  -p 8088:8088 \
  -v /tmp/tc1-router.conf:/etc/nginx/conf.d/default.conf:ro \
  nginxinc/nginx-unprivileged:alpine
```

Confirm that the router remains running:

```bash
docker ps --filter name=tc1-router
```

Expected result includes:

```text
STATUS
Up ...

PORTS
0.0.0.0:8088->8088/tcp
```

Inspect the router logs:

```bash
docker logs tc1-router
```

Expected output includes:

```text
Configuration complete; ready for start up
start worker processes
```

---

## 2.12 Verify local path routing

### Backend route through the router

```bash
curl -i http://localhost:8088/api
```

Expected result:

```text
HTTP/1.1 200 OK
Content-Type: application/json
Access-Control-Allow-Origin: http://localhost:8088
```

Expected body:

```json
{"id":"<guid>"}
```

This proves that `/api` was sent to the backend container.

### Frontend route through the router

```bash
curl -sS -o /dev/null \
  -w '/ -> %{http_code} %{content_type}\n' \
  http://localhost:8088/
```

Expected result:

```text
/ -> 200 text/html
```

### SPA route through the router

```bash
curl -sS -o /dev/null \
  -w '/test-route -> %{http_code} %{content_type}\n' \
  http://localhost:8088/test-route
```

Expected result:

```text
/test-route -> 200 text/html
```

This proves that non-API traffic reaches the frontend and retains the React SPA
fallback.

---

## 2.13 Verify the complete browser flow

Open:

```text
http://localhost:8088
```

Expected page content:

```text
SUCCESS: <guid>
```

Then inspect recent backend logs:

```bash
docker logs tc1-backend --since 2m
```

Expected output includes a recent request:

```text
GET /api
```

Together, these results prove the complete request path:

```text
Browser
-> temporary router
-> React frontend
-> relative /api request
-> temporary router path rule
-> Express backend
-> GUID response
-> React SUCCESS message
```

Capture:

1. A browser screenshot showing `SUCCESS: <guid>`.
2. Backend logs showing the corresponding `GET /api`.
3. The non-root identity output from both containers.
4. The route-validation output from port `8088`.


---

## 2.14 Troubleshooting

### Docker command unavailable in WSL

Symptom:

```text
The command 'docker' could not be found in this WSL 2 distro
```

Correction:

1. Start Docker Desktop.
2. Enable the WSL 2 engine.
3. Enable integration for the active WSL distribution.
4. Run `wsl --shutdown` from Windows PowerShell.
5. Reopen WSL.
6. Confirm that `docker version` displays both Client and Server sections.

### Docker socket permission denied

Symptom:

```text
permission denied while trying to connect to the Docker API
```

Temporary method:

```bash
sudo docker ps
```

Local development method:

```bash
sudo usermod -aG docker "$USER"
```

Close the WSL session, run `wsl --shutdown` from Windows PowerShell, then reopen
WSL.

Confirm membership:

```bash
groups
docker ps
```

The Docker group grants control equivalent to root through the Docker daemon.
Use it only as a conscious workstation decision.

### Router exits with `/run/nginx.pid` permission denied

Symptom:

```text
open() "/run/nginx.pid" failed (13: Permission denied)
```

Cause:

The temporary configuration replaced the image's full
`/etc/nginx/nginx.conf`. That removed settings supplied by the unprivileged
Nginx image.

Incorrect mount:

```bash
-v /tmp/tc1-router.conf:/etc/nginx/nginx.conf:ro
```

Correct mount:

```bash
-v /tmp/tc1-router.conf:/etc/nginx/conf.d/default.conf:ro
```

Only the server block should be replaced. The image's main Nginx configuration
must remain intact.

### Frontend works but displays a fetch or JSON error on port 3000

Opening the frontend directly at:

```text
http://localhost:3000
```

causes the relative `/api` request to return to the frontend container.

Use:

```text
http://localhost:8088
```

for the integrated local test. Port `8088` supplies the same path-routing role
planned for the AWS Application Load Balancer.

### Container exists but is not running after a WSL restart

Check all containers:

```bash
docker ps -a
```

Start the existing container:

```bash
docker start tc1-backend
docker start tc1-frontend
docker start tc2-router
```

Confirm the state:

```bash
docker ps
```

Local containers were created without a restart policy. ECS will manage task
replacement in AWS.

---

## 2.15 Cleanup

Remove the temporary router:

```bash
docker rm -f tc1-router
rm -f /tmp/tc1-router.conf
```

Remove the frontend and backend containers:

```bash
docker rm -f tc1-frontend tc1-backend
```

Remove the local network:

```bash
docker network rm tc1-net
```

Optional local image cleanup:

```bash
docker image rm tc1-frontend:phase2
docker image rm tc1-backend:phase2
```

Do not remove the images when they are still needed for later local testing.

---

## Phase 2 result

Phase 2 demonstrated that:

- The supplied backend runs successfully in Node.js 24.
- The backend process runs as a non-root user.
- The legacy frontend builds under its pinned Node.js version.
- Node.js 16 is absent from the final frontend runtime image.
- The frontend runs under unprivileged Nginx.
- The frontend and backend work through one browser origin.
- Relative `/api` routing is compatible with the planned ALB architecture.