# Runner Installation
To install and register a Daytona Runner on your system, follow these steps:

## Prerequisites

- **Supported OS Architecture:** AMD64/x86_64
- **Docker:** The script will install Docker if not present.
- **Systemd:** Required for service management.

## Installation Steps

1. **Run the Runner Install Script**

```bash
curl -sSL https://download.daytona.io/install.sh | sudo bash
```

The script will prompt you for:
- Daytona API URL
- Daytona Admin API Key
- System resource allocation (CPU, memory, disk)
- Domain name for the runner
- Runner API URL
- Optional proxy URL, region, runner capacity, and runner API key

2. **Automatic Steps Performed by the Script**

- Checks system architecture
- Downloads the Daytona runner binary
- Installs Docker if missing
- Registers the runner with the Daytona API
- Creates and enables a systemd service for the runner
- Starts the runner service

## Managing the Runner Service

- **Check status:**
```bash
sudo systemctl status daytona-runner
```
- **View logs:**
```bash
sudo tail -f /var/log/daytona-runner.log
```
- **Stop service:**
```bash
sudo systemctl stop daytona-runner
```

For more details and troubleshooting, visit [Daytona Runner Installation Docs](https://docs.daytona.io/docs/runner/installation).

## Override with env vars
The following environment variables can be set to override default values in the install script:

| Variable Name            | Description                                                      | Default Value / Notes                       |
|------------------------- |------------------------------------------------------------------|---------------------------------------------|
| `CONTAINER_RUNTIME`      | Container runtime to use                                         | `sysbox-runc`                              |
| `API_TOKEN`              | API token for runner                                             | Auto-generated or user-provided            |
| `TLS_CERT_FILE`          | Path to TLS certificate file                                     | `/etc/letsencrypt/live/$DOMAIN/fullchain.pem` |
| `TLS_KEY_FILE`           | Path to TLS key file                                             | `/etc/letsencrypt/live/$DOMAIN/privkey.pem`   |
| `ENABLE_TLS`             | Enable TLS for runner                                            | `false`                                    |
| `API_PORT`               | Port for runner API                                              | `3000`                                     |
| `LOG_FILE_PATH`          | Path to runner log file                                          | `/var/log/daytona-runner.log`               |
| `LOG_LEVEL`              | Log level                                                        | `info`                                     |
| `AWS_ENDPOINT_URL`       | AWS S3 endpoint URL                                              | `https://s3.us-east-1.amazonaws.com`        |
| `AWS_ACCESS_KEY_ID`      | AWS access key ID                                                | (empty)                                    |
| `AWS_SECRET_ACCESS_KEY`  | AWS secret access key                                            | (empty)                                    |
| `AWS_REGION`             | AWS region                                                       | `us-east-1`                                |
| `AWS_DEFAULT_BUCKET`     | AWS S3 bucket name                                               | `daytona`                                  |
| `SSH_GATEWAY_ENABLE`     | Enable SSH gateway                                               | `true` or `false` (auto-detected)          |
| `SSH_PUBLIC_KEY`         | SSH gateway public key                                           | Fetched from API                           |
| `SSH_HOST_KEY_PATH`      | Path to SSH host key                                             | `/etc/ssh/ssh_host_rsa_key`                |
| `SERVER_URL`             | Daytona API URL                                                  | User-provided                              |

You can set these variables before running the install script to customize the runner configuration.
