import React, { useEffect, useState } from 'react'
import './App.css';
import API_URL from './config'

function App() {
  const [successMessage, setSuccessMessage] = useState() 
  const [failureMessage, setFailureMessage] = useState() 

  useEffect(() => {
    const getId = async () => {
      try {
        const resp = await fetch(API_URL)
        if (!resp.ok) {
          throw new Error(`Backend request failed with status ${resp.status}`)
        }
        const data = await resp.json()
        setSuccessMessage(data.id)
      }
      catch(e) {
        setFailureMessage(e.message)
      }
    }
    getId()
  }, [])

  return (
    <div className="App">
      {!failureMessage && !successMessage ? 'Fetching...' : null}
      {failureMessage ? failureMessage : null}
      {successMessage ? `SUCCESS: ${successMessage}` : null}
    </div>
  );
}

export default App;
