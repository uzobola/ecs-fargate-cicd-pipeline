const express = require('express')
const { v4: uuidv4 } = require('uuid');
const { CORS_ORIGIN } = require('./config')

const ID = uuidv4()
const PORT = 8080

const app = express()
app.use(express.json())

app.use((req, res, next) => {
    res.setHeader('Access-Control-Allow-Origin', CORS_ORIGIN)
    res.setHeader('Access-Control-Allow-Methods', 'GET')
    res.setHeader('Access-Control-Allow-Headers', '*')
    next();
})
// Dedicated health route so the ALB target group health check is testing
// something real, not coincidentally passing because every path returns 200.
app.get('/health', (req, res) => {
    res.json({ status: 'ok' })
})

// The one real data route the frontend calls. Matches '/api' and '/api/'
// (Express non-strict routing treats a trailing slash as equivalent).
app.get('/api', (req, res) => {
    console.log(`${new Date().toISOString()} GET /api`)
    res.json({id: ID})
})

app.listen(PORT, () => {
    console.log(`Backend started on ${PORT}. ctrl+c to exit`)
})