# Frontend

The Failure Scenarios dashboard is a static HTML page served by Nginx.

Run these commands from the repository root:

```powershell
docker build -t rca-lab-frontend:latest -f apps/frontend/Dockerfile apps/frontend
docker run --rm -d --name rca-lab-frontend -p 8080:80 rca-lab-frontend:latest
```

Open `http://localhost:8080`. Stop the container with:

```powershell
docker stop rca-lab-frontend
```
