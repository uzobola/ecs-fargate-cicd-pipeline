

## ADR-001: Pin Node.js 16.20.2 for the supplied frontend

### Context

Running the supplied `react-scripts 4.0.3` frontend with Node.js 24 produced
`ERR_OSSL_EVP_UNSUPPORTED` during the Webpack build process.

### Decision

Pin local development and frontend build operations to Node.js 16.20.2 using
the repository `.nvmrc` file.

### Reason

This matches the application’s tested environment and avoids modifying the
supplied application toolchain during an infrastructure-focused challenge.

### Consequences

- Local and pipeline builds must use the pinned Node version.
- The existing frontend toolchain remains unchanged.
- A later modernization should update the frontend build system and revalidate
  the application under a current Node.js release.
