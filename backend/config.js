module.exports = {
    // Overridable via ECS task definition env var in AWS; falls back to
    // local dev default when running with `npm start` outside a container.
    CORS_ORIGIN: process.env.CORS_ORIGIN || 'http://localhost:3000'
}