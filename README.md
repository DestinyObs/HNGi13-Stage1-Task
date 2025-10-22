# HNG DevOps Stage 1 — Automated Deployment Script

## Overview

This Bash script automates the deployment of containerized applications to a remote Linux server.
It supports repositories that contain either a **Dockerfile** or a **docker-compose.yml** file.

## Features

* Automatically clones or updates the project repository.
* Detects and deploys either a Dockerfile or Docker Compose configuration.
* Sets up Docker, Docker Compose, and Nginx on the remote server.
* Configures Nginx as a reverse proxy for the deployed application.
* Validates deployment by checking container and service status.
* Includes a cleanup mode to remove deployed resources.

## Usage

### 1. Make the Script Executable

```bash
chmod +x deploy.sh
```

### 2. Run the Deployment Script

```bash
./deploy.sh
```

You will be prompted for the following inputs:

| Prompt                      | Description                                         |
| --------------------------- | --------------------------------------------------- |
| Git repository URL          | URL of the repository to deploy                     |
| Personal Access Token (PAT) | GitHub PAT for authentication                       |
| Branch name                 | Defaults to `main` if left blank                    |
| Remote server username      | SSH username for the target server                  |
| Remote server IP address    | Public IP of the EC2 or remote host                 |
| SSH key path                | Path to the private key (e.g., `~/path.pem`) |
| Application port            | Internal port exposed by the container              |


### 3. Deployment Flow

1. The script clones or updates the Git repository.
2. It checks for a `Dockerfile` or `docker-compose.yml`.
3. It verifies SSH connectivity to the remote host.
4. Installs and starts Docker, Docker Compose, and Nginx on the server.
5. Deploys the application using Docker or Docker Compose.
6. Configures Nginx as a reverse proxy on port 80.
7. Validates the deployment and logs all actions.

---

### 4. Cleanup Mode

To remove deployed resources from the remote server, use:

```bash
./deploy.sh --cleanup
```

This will:

* Stop and remove containers.
* Delete the application directory.
* Remove the Nginx configuration for the project.

---

## Logs

Each run generates a log file in the same directory with the format:

```
deploy_YYYYMMDD_HHMMSS.log
```

All key actions and errors are recorded for review.

---

## Notes

* Ensure the SSH key provided has correct permissions:

  ```bash
  chmod 400 ~/path.pem
  ```
* If SSH host verification fails, connect once manually:

  ```bash
  ssh -i ~/.ssh/ubuntu.pem ubuntu@<REMOTE_IP>
  ```
* The script uses port 80 for Nginx reverse proxy by default.
* Works for both Docker and Docker Compose setups.

---

**Author:** Destiny Obueh
**Track:** DevOps
**Task:** HNG13 Stage 1 — Automated Deployment Script
