# Znuny on Azure — Deployment

Infrastructure-as-code and CI/CD to publish Znuny on **Azure Container Apps**
with **Azure Database for MySQL** (Flexible Server).

```
deploy/
├── docker/
│   ├── Dockerfile          # Apache2 + mod_perl image built from this repo
│   ├── entrypoint.sh       # waits for DB, loads schema on first boot, starts daemon + Apache
│   └── Config.pm           # env-driven Kernel/Config.pm (no secrets in the image)
├── azure/
│   ├── main.bicep          # ACR + MySQL Flexible Server + Container Apps
│   └── main.parameters.example.json
├── docker-compose.yml      # local test stack (MariaDB)
└── README.md
.github/workflows/azure-deploy.yaml   # build in ACR + deploy
```

## Architecture

```
  Internet ──HTTPS──▶ Container Apps ingress ──▶ Znuny container (Apache/mod_perl :8080)
                                                        │
                                                        └──TLS──▶ Azure Database for MySQL
  Image source: Azure Container Registry (built with `az acr build`)
  Logs: Log Analytics workspace
```

The Znuny background **daemon** runs inside the same container (`minReplicas: 1`
keeps it alive). For higher load, split it into a dedicated Container Apps job.

---

## 1. Test locally first

```bash
docker compose -f deploy/docker-compose.yml up --build
# open http://localhost:8080/   →   login: root@localhost  /  root
```

The entrypoint loads the schema automatically on the first boot against an empty
database.

## 2. One-time Azure setup

Create an app registration with an **OIDC federated credential** for this repo
and grant it `Contributor` on the target subscription/resource group. Then add
these **repository secrets**:

| Secret | Description |
| --- | --- |
| `AZURE_CLIENT_ID` | App registration (or user-assigned identity) client id |
| `AZURE_TENANT_ID` | Azure AD tenant id |
| `AZURE_SUBSCRIPTION_ID` | Target subscription id |
| `MYSQL_ADMIN_PASSWORD` | Strong password for the MySQL admin user |

## 3. Deploy

Run the **Deploy Znuny to Azure** workflow (Actions tab → Run workflow), or
deploy manually with the Azure CLI:

```bash
az group create -n znuny-rg -l eastus

az deployment group create \
  -g znuny-rg \
  -f deploy/azure/main.bicep \
  -p deploy/azure/main.parameters.example.json \
  -p mysqlAdminPassword='<strong-password>'

# Build & push the image into the ACR created above, then point the app at it:
ACR=$(az deployment group show -g znuny-rg -n main --query properties.outputs.acrName.value -o tsv)
az acr build --registry "$ACR" --image znuny:latest -f deploy/docker/Dockerfile .

APP=$(az deployment group show -g znuny-rg -n main --query properties.outputs.containerAppName.value -o tsv)
SERVER=$(az deployment group show -g znuny-rg -n main --query properties.outputs.acrLoginServer.value -o tsv)
az containerapp update -g znuny-rg -n "$APP" --image "$SERVER/znuny:latest"

az deployment group show -g znuny-rg -n main --query properties.outputs.appUrl.value -o tsv
```

The CI workflow does exactly these steps: deploy Bicep → `az acr build` → update
the Container App image.

### Turnkey script (recommended for a first manual deploy)

`deploy/azure/provision.sh` wraps all of the above. Run it from a machine that
is authenticated to the target subscription (e.g. **SERPRO-CLOUD**):

```bash
export AZURE_SUBSCRIPTION_ID="<subscription-id>"   # SERPRO-CLOUD subscription
export MYSQL_ADMIN_PASSWORD='<strong-password>'
# defaults: RESOURCE_GROUP=znuny-rg  LOCATION=brazilsouth  NAME_PREFIX=znuny
./deploy/azure/provision.sh
```

Notes for SERPRO-CLOUD / Brazil:

- The default region is **`brazilsouth`** (Azure public cloud). Override with
  `LOCATION=...` if a different region is required.
- For a sovereign/other Azure endpoint, run `az cloud set --name <cloud>`
  before the script.
- The subscription id is passed as an environment variable — it is not stored
  in the repository.

## 4. First login

1. Open the app URL. Default admin: `root@localhost` / `root`.
2. **Change the password immediately** (top-right → Personal preferences).
3. Configure SysConfig (mail, FQDN, etc.) through the web interface.

---

## Configuration reference (container env vars)

| Variable | Default | Purpose |
| --- | --- | --- |
| `ZNUNY_DB_HOST` | `127.0.0.1` | MySQL host (Flexible Server FQDN) |
| `ZNUNY_DB_PORT` | `3306` | MySQL port |
| `ZNUNY_DB_NAME` | `znuny` | Database name |
| `ZNUNY_DB_USER` | `znuny` | Database user |
| `ZNUNY_DB_PASSWORD` | — | Database password (from a secret) |
| `ZNUNY_DB_SSL` | `required` | `required` forces TLS; `disabled` turns it off (local only) |
| `ZNUNY_DB_SSL_CA` | — | Path or URL to a CA bundle for full certificate verification |
| `ZNUNY_DB_AUTO_SCHEMA` | `1` | Load schema on first boot when the DB is empty |
| `ZNUNY_RUN_DAEMON` | `1` | Run the Znuny background daemon in this container |
| `ZNUNY_FQDN` | — | Public hostname (set to the ingress FQDN or custom domain) |
| `ZNUNY_HTTP_TYPE` | `https` | Scheme advertised to Znuny (ingress terminates TLS) |

### Full TLS certificate verification (optional)

Azure MySQL Flexible Server enforces TLS. `ZNUNY_DB_SSL=required` encrypts the
connection. To also **verify** the server certificate, set:

```
ZNUNY_DB_SSL_CA=https://dl.cacerts.digicert.com/DigiCertGlobalRootG2.crt.pem
```

The entrypoint downloads it and the app connects with `mysql_ssl_ca_file`.

## Notes & production hardening

- **Secrets**: DB password is stored as a Container Apps secret, never baked in
  the image. For stronger isolation, wire secrets to **Azure Key Vault**.
- **Networking**: the template uses public access + the "allow Azure services"
  firewall rule. For production, put both the Container Apps environment and
  MySQL on a **VNet** and disable public access.
- **Custom domain / TLS**: add a managed certificate and custom domain on the
  Container App ingress, then set `ZNUNY_FQDN` accordingly.
- **Backups**: MySQL Flexible Server has automated backups (7 days here). Also
  back up Znuny article/attachment data — move attachments to the database or a
  mounted Azure Files share if you need them to survive replica restarts.
- **Scaling**: `minReplicas: 1` is required so the single daemon keeps running.
  If you scale the web tier out, run the daemon as a separate single-replica app
  and set `ZNUNY_RUN_DAEMON=0` on the web replicas.
