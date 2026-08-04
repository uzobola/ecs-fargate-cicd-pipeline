// CRA inlines REACT_APP_* vars at build time from .env.development (npm start)
// or .env.production (npm run build) - no runtime injection needed since
// frontend and backend sit behind the same ALB in prod (relative /api works).
export const API_URL = process.env.REACT_APP_BACKEND_URL || 'http://localhost:8080/api'
export default API_URL