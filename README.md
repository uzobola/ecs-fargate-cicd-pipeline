# Overview
This repository contains a React frontend, and an Express backend that the frontend connects to.


## Implementation Status

- [x] Local backend validation
- [x] Local frontend validation
- [x] Environment-based API and CORS configuration
- [x] Dedicated backend health endpoint
- [x] Backend container validation
- [x] Frontend container validation
- [x] Local path-routing integration validation
- [ ] ECR and Terraform foundation
- [ ] ECS Fargate deployment
- [ ] Jenkins pipeline
- [ ] Auto Scaling validation
- [ ] Final deployment documentation



### Node.js compatibility

The supplied frontend uses React 17 and `react-scripts 4.0.3`. Frontend
development and build operations are pinned to Node.js 16.20.2 through
`frontend/.nvmrc`.

```bash
cd frontend
nvm use
node --version
```

Expected output:

```text
v16.20.2
```

The backend container targets Node.js 24 LTS. The legacy frontend Node.js
version is restricted to the temporary Docker build stage; the final frontend
image runs Nginx.

A future frontend modernization should replace the legacy build toolchain and
revalidate the application under a supported Node.js release. That migration
is outside this infrastructure-focused challenge.

