import http from 'node:http'

const port = Number(process.env.E2E_PORT ?? 4317)

const html = `<!doctype html>
<html lang="en">
  <head><meta charset="UTF-8"><title>DeepSeek Code Web Fixture</title></head>
  <body>
    <main>
      <h1>Repair fixture</h1>
      <p id="status" role="status">Idle</p>
      <button id="load-status">Load status</button>
      <button id="trigger-failure">Trigger failing request</button>
    </main>
    <script>
      document.querySelector('#load-status').addEventListener('click', async () => {
        const response = await fetch('/api/status')
        const data = await response.json()
        document.querySelector('#status').textContent = data.message
      })
      document.querySelector('#trigger-failure').addEventListener('click', async () => {
        const response = await fetch('/api/failure')
        if (!response.ok) console.error('Fixture request failed: ' + response.status)
      })
    </script>
  </body>
</html>`

const server = http.createServer((request, response) => {
  if (request.url === '/api/status') {
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ message: 'Service ready' }))
    return
  }
  if (request.url === '/api/failure') {
    response.writeHead(500, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ error: 'fixture failure' }))
    return
  }
  response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
  response.end(html)
})

server.listen(port, '127.0.0.1', () => {
  process.stdout.write(`fixture-ready:${port}\n`)
})

process.on('SIGTERM', () => server.close(() => process.exit(0)))
process.on('SIGINT', () => server.close(() => process.exit(0)))
