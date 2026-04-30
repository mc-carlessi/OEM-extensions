# Oracle Enterprise Manager 24ai - MySQL Monitoring Scripts

This repository contains a collection of scripts designed to extend the monitoring capabilities of **Oracle Enterprise Manager (OEM) 24ai** for MySQL Enterprise environments using **Metric Extensions**.

> [!IMPORTANT]
> These scripts are provided for illustrative purposes only and should not be considered official recommendations or supported products from Oracle. It is highly recommended to test them thoroughly in a development environment before deploying to production.

> [!NOTE]
> Special thanks to the AI assistance that helped refine the logic, robustness, and failover capabilities of these scripts.

---

## Overview

Monitoring a MySQL InnoDB Cluster requires visibility not only into the database nodes but also into the **MySQL Router** instances that manage application traffic. 

The scripts in this repository are optimized to be used as "OS Command" adapters within OEM Metric Extensions, allowing you to collect custom metrics and trigger alerts based on specific thresholds within the OEM console.

---

## Featured Script: `mysql_router_status.pl`

This Perl script provides a comprehensive health check for all MySQL Routers registered within an InnoDB Cluster.

### Key Features
* **Metadata-Driven Discovery**: Automatically retrieves the list of all registered routers and their REST API ports directly from the MySQL InnoDB Cluster metadata tables.
* **Built-in Failover Logic**: Designed for High Availability (HA). If the `MYSQL_HOST` variable contains a comma-separated list of multiple cluster nodes, the script will automatically cycle through them until a successful metadata query is performed.
* **REST API Integration**: Directly queries each Router's native REST API to verify its actual operational status, software version, and uptime.
* **OEM Optimized**: Outputs data in a pipe-separated format (`|`), ready for easy mapping into columns within the Metric Extension UI.

### Metric Output Columns
The script returns one row per router with the following columns:
1.  **ROUTER_ID**: Unique identifier of the router instance.
2.  **ADDRESS**: Hostname or IP address of the router.
3.  **PORT**: The HTTP/REST API port used for monitoring.
4.  **STATUS**: Boolean value (1 = Up, 0 = Down).
5.  **VERSION**: The version of the MySQL Router software.
6.  **UPTIME**: Human-readable uptime (e.g., `2d 04h 10m 15s`).

---

## Deployment in Oracle Enterprise Manager

To implement this script in OEM 24ai, follow these steps:

### 1. Prerequisites
* Script is written in per to benefit of `perl` provided by EOM Agent.
* The `mysql` client must be available in the system path of the monitoring user.
* The MySQL Router instances must have the **REST API** enabled.

### 2. Metric Extension Configuration
* **REST API credentials**: create a credential set (type: MySQL InnoDB Cluster) to store credentials 
* **Adapter Type**: OS Command.
* **Command**: `perl ./mysql_router_status.pl`
* **Environment Variables**:
    * `MYSQL_HOST`: Comma-separated list of cluster IPs/hostnames (e.g., `%hostname%,%other_node%`).
    * `MYSQL_PORT`: Port for the metadata connection (usually `6446` or `3306`).

### 3. Credentials (Input Setup)
The script reads sensitive credentials from **Standard Input (STDIN)** for security. In the Metric Extension "Input Setup", map the following:

| Parameter | Description |
| :--- | :--- |
| `MYSQL_USERNAME` | DB User with read privileges on `mysql_innodb_cluster_metadata`. |
| `MYSQL_PASSWORD` | Password for the Database User. |
| `OracleMySQLUsername` | Username for the Router REST API. |
| `OracleMySQLPassword` | Password for the Router REST API. |

---

## Example Output
```text
1|server1.example.com|8443|1|8.4.9|12d 05h 20m 01s
2|server2.example.com|8443|1|8.4.8|12d 05h 18m 45s
